{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example.Server where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.Error.Either (runError)
import Control.Carrier.Reader (ask, runReader)
import Control.Carrier.State.Strict
  ( State,
    get,
    modify,
  )
import Control.Monad (forever, void)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Data (Proxy (Proxy))
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Example.Metric
import Example.Type
import Example.Work
import Process.HasServer (HasServer, cast, runWithServer)
import Process.HasWorkGroup
  ( HasWorkGroup,
    castAll,
    castById,
    clearTVar,
    createWorker,
    deleteChan,
    getAllInfo,
    killWorker,
    sendAllCall,
    sendWorks,
    timeoutCallAll,
  )
import Process.Metric
  ( Metric,
    getAll,
    inc,
    showMetric,
  )
import Process.Util
  ( MessageChan,
    runWorkerWithChan,
    withResp,
    withThreeMessageChan,
  )

-------------------------------------Manager - Work, Manager

server ::
  ( MonadIO m,
    HasServer "log" SigLog '[Log] sig m,
    Has (MessageChan SigLog :+: State IntSet :+: Metric Wmetric) sig m,
    HasWorkGroup "w" SigCommand '[Stop, Info, ProcessStartTimeoutCheck, ProcessWork] sig m,
    Has (MessageChan SigTimeoutCheck :+: MessageChan SigException :+: MessageChan SigCreate) sig m
  ) =>
  m ()
server = forever $ do
  withThreeMessageChan
    @SigTimeoutCheck
    @SigException
    @SigCreate
    ( \case
        SigTimeoutCheck1 (StartTimoutCheck rsp) ->
          withResp
            rsp
            ( do
                cast @"log" $ LD "send all check message to works"
                inc all_start_timeout_check
                sendAllCall @"w" ProcessStartTimeoutCheck
            )
        SigTimeoutCheck2 (ProcessTimeout pid) -> do
          inc all_timeout
          modify $ IntSet.insert pid
          cast @"log" $ LE $ "pid: " ++ show pid ++ " health check timeout!!!"
    )
    ( \case
        SigException1 (ProcessR i res) -> do
          inc all_exception
          cast @"log" $ LW $ "some process terminate " ++ show (i, res)
          clearTVar @SigCommand i -- clean tvar
          cast @"log" $ LE $ "some tVar clear: [" ++ show i ++ "]"
          deleteChan @SigCommand i -- remove process channel
    )
    ( \case
        SigCreate1 Create -> do
          cast @"log" $ LW "fork a work process"
          slog <- ask
          inc all_create
          createWorker @SigCommand $ \idx ch ->
            void $
              runWorkerWithChan ch $
                runReader (WorkInfo idx) $
                  runError @TerminateProcess $
                    runWithServer @"log"
                      slog
                      mWork
        SigCreate2 (GetInfo rsp) ->
          withResp
            rsp
            ( do
                allM <- getAll @Wmetric Proxy
                cast @"log" $ LE $ showMetric allM
                timeoutCallAll @"w" 1_000_000 Info
            )
        SigCreate3 (StopProcess i) -> do
          castById @"w" i Stop
          deleteChan @SigCommand i
        SigCreate4 (KillProcess i) -> do
          killWorker @SigCommand i
          deleteChan @SigCommand i
        SigCreate5 (Fwork ios) -> do
          res <- sendWorks @"w" ios ProcessWork
          inc all_fork_work
          cast @"log" $ LW $ show $ snd res
        SigCreate6 StopAll -> do
          castAll @"w" Stop
        SigCreate7 (ToSet rsp) ->
          withResp rsp get
        SigCreate8 (GetProcessInfo rsp) ->
          withResp rsp (getAllInfo @SigCommand)
        SigCreate9 LogStatus -> do
          allM <- getAll @Wmetric Proxy
          cast @"log" $ LD $ showMetric allM
    )
