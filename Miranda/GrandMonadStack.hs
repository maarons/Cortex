module Cortex.Miranda.GrandMonadStack
    ( GrandMonadStack
    , LesserMonadStack
    ) where

-- Functional dependencies with multiple monads of the same type (State monads
-- in this instance) suck big time.  GHC wasn't able to compile the code, so
-- instead this ugly static monad stack is used.

import Control.Monad.State (StateT)
import Control.Monad.Error (ErrorT)
import Control.Concurrent.Lifted (MVar)

import Cortex.Miranda.ValueStorage (ValueStorage)

type LesserMonadStack = ErrorT String IO

-- First state holds storage location.  Second one holds the timestamp of last
-- squash operation (time of an initiated operation, not a mirrored squash) and
-- the value storage.
type GrandMonadStack = StateT String (StateT (MVar String, MVar ValueStorage) LesserMonadStack)

