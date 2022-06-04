module Main where

import Example.R (runmProcess)
import qualified Process.Effect.Example.T1 as T
import Raft.T as T

main :: IO ()
main = T.runval1

-- T.r1
-- runmProcess
