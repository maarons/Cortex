module Cortex.Miranda.Storage
    ( set
    , delete
    , lookup
    , lookupHash
    , lookupAll
    , lookupAllWhere
    , insert
    , member
    , getCommits
    , runStorage
    , Cortex.Miranda.Storage.show
    , Cortex.Miranda.Storage.read
    ) where

-----

import Prelude hiding (lookup)
import Control.Monad.State
import Control.Monad.Error
import Control.Concurrent.Lifted
import Data.Maybe (fromJust, isNothing, listToMaybe)

import Cortex.Miranda.ValueStorage (ValueStorage)
import qualified Cortex.Miranda.ValueStorage as VS
import Cortex.Miranda.Commit (Commit)
import qualified Cortex.Miranda.Commit as Commit
import Cortex.Miranda.GrandMonadStack

-----

runStorage :: GrandMonadStack a -> String -> LesserMonadStack ()
runStorage s location = do
    mv <- newMVar VS.empty
    runStateT (runStateT s location) mv
    return ()

-----

getVS :: GrandMonadStack ValueStorage
getVS = (lift get) >>= takeMVar

-----

putVS :: ValueStorage -> GrandMonadStack ()
putVS vs = (lift get) >>= (flip putMVar) vs

-----

readVS :: GrandMonadStack ValueStorage
readVS = (lift get) >>= readMVar

-----

set ::  String -> String -> GrandMonadStack ()
set key value = getVS >>= VS.set key value >>= putVS

-----

delete :: String -> GrandMonadStack ()
delete key = getVS >>= VS.delete key >>= putVS

-----

lookup :: String -> GrandMonadStack (Maybe String)
lookup key = do
    vs <- readVS
    VS.lookup key vs

-----

lookupHash :: String -> GrandMonadStack (Maybe String)
lookupHash key = do
    vs <- readVS
    VS.lookupHash key vs

-----

lookupAll :: String -> GrandMonadStack [(String, String)]
lookupAll key = do
    vs <- readVS
    VS.lookupAll key vs

-----

lookupAllWhere :: String -> (String -> String -> Bool) ->
    GrandMonadStack [(String, String)]
lookupAllWhere key f = do
    vs <- readVS
    VS.lookupAllWhere key f vs

-----

insert :: Commit -> GrandMonadStack ()
insert c = do
    vs <- getVS
    putVS $ VS.insert c vs

-----

member :: Commit.Hash -> GrandMonadStack Bool
member hash = do
    vs <- readVS
    let b = VS.member hash vs
    putVS vs
    return b

-----

getCommits :: GrandMonadStack [Commit]
getCommits = do
    vs <- readVS
    let commits = VS.getCommits vs
    return commits

-----

show :: GrandMonadStack String
show = do
    vs <- readVS
    let s = Prelude.show vs
    return s

-----

read :: String -> GrandMonadStack ()
read s = do
    -- Remove the old MVar value.
    getVS
    let vs = maybeRead s
    when (isNothing vs) (throwError "Couldn't parse ValueStorage")
    putVS $ fromJust vs

maybeRead :: String -> Maybe ValueStorage
maybeRead = fmap fst . listToMaybe . reads
