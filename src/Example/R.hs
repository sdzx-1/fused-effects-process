{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Example.R where

import Control.Carrier.Reader (runReader)
import Control.Carrier.State.Strict
import Control.Concurrent (forkIO, takeMVar)
import Control.Concurrent.MVar (newEmptyMVar)
import Control.Concurrent.STM (newTVarIO)
import Control.Monad (void)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Example.Client
import Example.EOT
import Example.Log
import Example.Metric
import Example.PTC
import Example.Server
import Example.Type
import Process.HasServer (runWithServer)
import Process.HasWorkGroup
import Process.Metric
import Process.Type (NodeId)
import Process.Util

----------------- run mProcess

runmProcess :: IO ()
runmProcess = do
  print "create resource"

  stimeout <- newMessageChan @SigTimeoutCheck
  se <- newMessageChan @SigException
  sc <- newMessageChan @SigCreate
  slog <- newMessageChan @SigLog
  tvar <- newTVarIO Map.empty
  ftmvar <- newEmptyMVar @()

  print "fork log server"
  forkIO $
    void $
      runMetric @Lines $
        runState logState $
          runServerWithChan slog logServer

  print "fork et process"
  forkIO $
    void $
      runWithServer @"et" se $
        runWithServer @"log" slog $
          runMetric @ETmetric $
            runReader
              (EotConfig 1_000_000 tvar)
              eotProcess

  print "fork ptc process"
  forkIO $
    void $
      runWithServer @"ptc" stimeout $
        runMetric @PTmetric $
          runWithServer @"log" slog $
            runReader
              (PtConfig 1_000_000)
              ptcProcess

  print "fork server process"
  forkIO $
    void $
      runServerWithChan stimeout $
        runServerWithChan se $
          runServerWithChan sc $
            runWithServer @"log" slog $
              runReader slog $
                runMetric @Wmetric $
                  runState @(Set NodeId) Set.empty $
                    runWithWorkGroup' @"w"
                      tvar
                      server

  print "fork client"
  forkIO $
    void $
      runWithServer @"log" slog $
        runReader ftmvar $
          runWithServer @"s" sc client

  forkIO $ void $ runWithServer @"s" sc ls
  takeMVar ftmvar
