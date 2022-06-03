module Main where

import Control.Effect.T
import qualified Control.Effect.Texample as T
import Example.R (runmProcess)
import Raft.T as T

main :: IO ()
main = T.runval1

-- T.r1
-- runmProcess
