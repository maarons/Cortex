{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}

module Cortex.Miranda.Server
    ( runServer
    ) where

-----

import Prelude hiding (getLine)
import Network
import System.IO (IOMode (ReadMode, WriteMode))
import System.Cmd (rawSystem)
import Control.Monad.State
import Control.Monad.Error
import Control.Concurrent.Lifted
import Data.Maybe (fromMaybe, fromJust, isNothing)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Char8 as BS
import System.Random (randomIO)

import Cortex.Common.ErrorIO (iListenOn, iAccept, iPrintLog, iConnectTo)
import Cortex.Common.LazyIO
import Cortex.Common.Event
import Cortex.Common.Error
import Cortex.Common.MaybeRead
import Cortex.Common.Time
import Cortex.Miranda.Commit (Commit)
import qualified Cortex.Miranda.Commit as C
import qualified Cortex.Miranda.Storage as S
import qualified Cortex.Common.Random as Random
import Cortex.Miranda.GrandMonadStack
import Cortex.Common.ByteString

import qualified Cortex.Miranda.Config as Config

-----

type ConnectedMonadStack = StateT (LazyHandle, String, Int) GrandMonadStack

-----

runServer :: Int -> GrandMonadStack ()
runServer serverPort = do
    readValueStorage
    -- Only commit instances are in the value storage now so we can remove
    -- everything that isn't.
    iPrintLog "Removing not used files from storage."
    S.cleanup
    iPrintLog "Storage cleanup done."
    periodicTimer Config.storageTime saveValueStorage
    socket <- iListenOn serverPort
    printLocalLog $ "Server started on port " ++ (show serverPort)
    -- Start sync daemon.
    periodicTimer Config.syncTime (sync serverPort)
    forever $ catchError (acceptConnection socket) reportError
    where
        acceptConnection :: Socket -> GrandMonadStack ()
        acceptConnection socket = do
            (hdl, host, port) <- iAccept socket
            fork $ evalStateT handleConnection (hdl, host, port)
            -- Ignore result of fork and return proper type.
            return ()

-----

-- `fork` discards errors, so `reportError` from `runServer` won't report them,
-- they have to be caught here.
handleConnection :: ConnectedMonadStack ()
handleConnection = catchError (getLine >>= chooseConnectionMode) reportError

-----

chooseConnectionMode :: LBS.ByteString -> ConnectedMonadStack ()

chooseConnectionMode "set" = do
    key <- getLine
    printLog $ "set: " ++ (LBS.unpack key)
    value <- getLine
    closeConnection
    lift $ S.set key value

chooseConnectionMode "lookup" = do
    key <- getLine
    printLog $ "lookup: " ++ (LBS.unpack key)
    value <- lift $ S.lookup key
    if (isNothing value)
        then putLine "Nothing"
        else do
            writePart "Just "
            putLine (fromJust value)
    closeConnection

chooseConnectionMode "lookup all" = do
    key <- getLine
    printLog $ "lookup all: " ++ (LBS.unpack key)
    kv <- lift $ S.lookupAll key
    let keys = fst $ unzip kv
    forM_ keys putSLine
    closeConnection

chooseConnectionMode "lookup all with value" = do
    key <- getLine
    printLog $ "lookup all with value: " ++ (LBS.unpack key)
    kv <- lift $ S.lookupAll key
    forM_ kv $ \(k, v) -> do
        { putSLine k
        ; putLine v
        }
    closeConnection

chooseConnectionMode "lookup hash" = do
    key <- getLine
    printLog $ "lookup hash: " ++ (LBS.unpack key)
    hash <- lift $ S.lookupHash key
    if (isNothing hash)
        then putLine "Nothing"
        else do
            writePart "Just "
            putSLine $ fromJust hash
    closeConnection

chooseConnectionMode "delete" = do
    key <- getLine
    printLog $ "delete: " ++ (LBS.unpack key)
    closeConnection
    lift $ S.delete key

chooseConnectionMode "sync" = do
    printLog "Sync request"
    host <- getLine
    -- If remote host was assumed offline, client side synchronisation will not
    -- mark it online.
    let key = LBS.append "host::availability::" host
    remote <- lift $ S.lookup key
    when ("offline" == fromMaybe "offline" remote) $ do
        lift $ S.set key "online"
        printLog $ concat ["Marked ", LBS.unpack host, " online"]
    -- If the remote performed a squash more recently, do it too.
    remoteSTime <- liftM LBS.unpack $ getLine
    localSTime <- lift S.getSquashTime
    when (localSTime < remoteSTime) $ lift $ do
        { printLocalLog "Local squash out of sync"
        ; performSquash
        ; S.setSquashTime remoteSTime
        }
    -- If local squash is more recent, silently abandon the sync.
    if (localSTime > remoteSTime)
        then do
            { printLog "Remote squash out of sync, abandoning"
            ; phonyClientSync
            }
        else clientSync 0
    printLog "Sync request done"

chooseConnectionMode _ = throwError "Unknown connection mode"

-----

-- Pretend we are up to date.
phonyClientSync :: ConnectedMonadStack ()
phonyClientSync = do
    -- Get a hash.
    getLine
    putLine "yes"

-- Answer questions about present commits.
clientSync :: Int -> ConnectedMonadStack ()
clientSync n = do
    hash <- getLine
    member <- lift $ S.member hash
    if member || (hash == "done")
        then do
            putLine "yes"
            clientSync' n
        else do
            putLine "no"
            clientSync $ n + 1

-- Collect remote commits.
clientSync' :: Int -> ConnectedMonadStack ()
clientSync' 0 = return ()
clientSync' n = do
    line <- getLine
    c <- lift $ C.fromString line
    lift $ S.insert c
    clientSync' $ n - 1

-----

sync :: Int -> GrandMonadStack ()
sync port = do
    let selfHost = LBS.pack $ concat [Config.host, ":", show port]
    let key = LBS.concat ["host::availability::", selfHost]
    self <- S.lookup key
    when ("offline" == fromMaybe "offline" self) (S.set key "online")
    hosts' <- S.lookupAllWhere "host::availability"
        (\k v ->
            toLazyBS k /= selfHost &&
            v == "online")
    let hosts = fst $ unzip hosts'
    r <- Random.generate (0, (length hosts) - 1) Config.syncServers
    let syncHosts = map (\i -> hosts !! i) r
    -- Decide if we should squash some commits first.
    when (Config.squashTime > 0.0) $ do
        let probability = Config.syncTime / Config.squashTime
        -- Roll the dice, random value between 0.0 and 1.0.
        (x :: Double) <- liftIO randomIO
        when (x < probability) $ do
            performSquash
            S.updateSquashTime
    forM_ syncHosts (performSync selfHost)

performSync :: LBS.ByteString -> BS.ByteString -> GrandMonadStack ()
performSync selfHost hostString = do
    printLocalLog $ "Synchronising with " ++ (BS.unpack hostString)
    let host = BS.unpack $ BS.takeWhile (/= ':') hostString
    let (port' :: Maybe Int) = maybeRead $ BS.unpack $ BS.tail $
            BS.dropWhile (/= ':') hostString
    when (isNothing port') $ throwError "Malformed host:port line"
    let port = fromJust port'
    do
        { hdl <- iConnectTo host port
        ; evalStateT (performSync' selfHost) (hdl, host, port)
        } `catchError` reportSyncError
    printLocalLog $ "Synchronisation with " ++ (BS.unpack hostString) ++ " done"
    where
        reportSyncError :: String -> GrandMonadStack ()
        reportSyncError e = do
            printLocalLog $ "Error: " ++ e
            printLocalLog $ concat ["Marking ", BS.unpack hostString, " offline"]
            let key = LBS.concat ["host::availability::", toLazyBS hostString]
            S.set key "offline"

-- Commits are first collected, then transmitted so they can be sent in oldest
-- to newest order.  This means they can be applied on the other side without
-- any unnecessary rebasing.
performSync' :: LBS.ByteString -> ConnectedMonadStack ()
performSync' selfHost = do
    putLine "sync"
    putLine selfHost
    -- Send local squash time.
    localSTime <- lift S.getSquashTime
    putLine $ LBS.pack localSTime
    -- Transmit commits to the remote.
    commits <- lift S.getCommits
    toTransmit <- performSync'' commits []
    performSync''' toTransmit
    closeConnection

performSync'' :: [Commit] -> [Commit] -> ConnectedMonadStack [Commit]
performSync'' [] t = do
    putLine "done"
    -- Collect "yes" answer from remote.
    getLine
    return t

performSync'' (c:commits) t = do
    putSLine $ C.getHash c
    l <- getLine
    if (l == "no")
        then performSync'' commits (c:t)
        else return t

performSync''' :: [Commit] -> ConnectedMonadStack ()
performSync''' [] = putLine "done"
performSync''' (h:t) = do
    cs <- lift $ C.toString h
    putLine cs
    performSync''' t

-----

readValueStorage :: GrandMonadStack ()
readValueStorage = do
    { storage <- get
    ; let location = concat [storage, "/data"]
    ; printLocalLog $ "Reading storage from " ++ location
    ; hdl <- lOpenFile location ReadMode
    ; vs <- lGetContents hdl
    ; lClose hdl
    ; S.read vs
    ; printLocalLog $ "Storage was successfully read"
    } `catchError` reportStorageError
    where
        reportStorageError :: String -> GrandMonadStack ()
        reportStorageError e = do
            printLocalLog $ "Couldn't read storage: " ++ e

-----

saveValueStorage :: GrandMonadStack ()
saveValueStorage = do
    { storage <- get
    ; let location = concat [storage, "/data"]
    ; let tmp = location ++ ".tmp"
    ; hdl <- lOpenFile tmp WriteMode
    ; vs <- S.show
    ; lPutStr hdl vs
    ; lClose hdl
    ; liftIO $ rawSystem "mv" [tmp, location]
    ; printLocalLog $ "Saved storage to " ++ location
    } `catchError` reportStorageError
    where
        reportStorageError :: String -> GrandMonadStack ()
        reportStorageError e = do
            printLocalLog $ "Saving storage failed: " ++ e

-----

performSquash :: GrandMonadStack ()
performSquash = do
    printLocalLog $ "Commit squash initiated"
    S.squash

-----

getLine :: ConnectedMonadStack LBS.ByteString
getLine = do
    (hdl, _, _) <- get
    lGetLine hdl

-----

putLine :: LBS.ByteString -> ConnectedMonadStack ()
putLine s = do
    (hdl, _, _) <- get
    lPutStrLn hdl s
    lFlush hdl

-----

putSLine :: BS.ByteString -> ConnectedMonadStack ()
putSLine = putLine . toLazyBS

-----

writePart :: LBS.ByteString -> ConnectedMonadStack ()
writePart s = do
    (hdl, _, _) <- get
    lPutStr hdl s

-----

getHost :: ConnectedMonadStack String
getHost = do
    (_, host, port) <- get
    return $ concat [host, ":", show port]

-----

closeConnection :: ConnectedMonadStack ()
closeConnection = do
    (hdl, _, _) <- get
    lClose hdl

-----

printLog :: String -> ConnectedMonadStack ()
printLog msg
    | Config.writeLog = do
        timeString <- getDefaultTimestamp
        host <- getHost
        iPrintLog $ concat [timeString, " -- ", host, " -- ", msg]
    | otherwise = return ()

-----

printLocalLog :: String -> GrandMonadStack ()
printLocalLog msg
    | Config.writeLog = do
        timeString <- getDefaultTimestamp
        iPrintLog $ concat [timeString, " -- ", msg]
    | otherwise = return ()

-----
