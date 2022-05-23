{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Raft.T where

import Control.Algebra (Has)
import Control.Carrier.State.Strict
  ( State,
    get,
    modify,
    put,
    runState,
  )
import Control.Concurrent
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMVar (readTMVar)
import Control.Monad (forM, forM_, forever, void)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.Map as Map
import Process.HasPeerGroup
  ( HasPeerGroup,
    NodeId (NodeId),
    NodeState (..),
    callAll,
    callById,
    getNodeId,
    runWithPeers',
  )
import Process.HasServer (HasServer, call, cast, runWithServer)
import Process.Metric
import Process.TChan (newTChanIO)
import Process.TH
import Process.Type
import Process.Util
import System.Random
import Prelude hiding (log)

data Role = Master | Slave deriving (Show)

data ChangeMaster where
  ChangeMaster :: RespVal () %1 -> ChangeMaster

data CallMsg where
  CallMsg :: RespVal Int %1 -> CallMsg

data Log where
  Log :: String -> Log

data Cal where
  Cal :: Cal

data Status where
  Status :: RespVal (NodeId, Role) %1 -> Status

mkSigAndClass
  "SigStatus"
  [ ''Status
  ]

mkSigAndClass
  "SigLog"
  [ ''Log,
    ''Cal
  ]

mkSigAndClass
  "SigRPC"
  [ ''CallMsg,
    ''ChangeMaster
  ]

mkMetric
  "LogMet"
  [ "all_log"
  ]

log ::
  ( MonadIO m,
    Has (Metric LogMet) sig m,
    Has (MessageChan SigLog) sig m
  ) =>
  m ()
log = forever $ do
  withMessageChan @SigLog \case
    SigLog1 (Log _) -> do
      inc all_log
    SigLog2 Cal -> do
      val <- getVal all_log
      liftIO $ print val
      putVal all_log 0

t00 ::
  ( MonadIO m,
    HasServer "status" SigStatus '[Status] sig m
  ) =>
  m ()
t00 = do
  val <- call @"status" $ Status
  liftIO $ print val
  liftIO $ threadDelay 100_000

t0 ::
  ( MonadIO m,
    HasServer "log" SigLog '[Cal] sig m
  ) =>
  m ()
t0 = forever $ do
  cast @"log" Cal
  liftIO $ threadDelay 1_000_000

t1 ::
  ( MonadIO m,
    Has (State Role) sig m,
    Has (MessageChan SigStatus) sig m,
    HasServer "log" SigLog '[Log] sig m,
    HasPeerGroup "peer" SigRPC '[CallMsg, ChangeMaster] sig m
  ) =>
  m ()
t1 = forever $ do
  handleFlushMsgs @SigStatus $ \case
    SigStatus1 (Status resp) -> withResp resp $ do
      r <- get
      nid <- getNodeId @"peer"
      pure (nid, r)

  get @Role >>= \case
    Master -> do
      res <- callAll @"peer" $ CallMsg
      vals <- forM res $ \(a, b) -> do
        val <- liftIO $ atomically $ readTMVar b
        pure (val, a)
      let mnid = snd $ maximum vals
      callById @"peer" mnid ChangeMaster
      put Slave
    Slave -> do
      handleMsg @"peer" $ \case
        SigRPC1 (CallMsg rsp) -> withResp rsp $ do
          liftIO $ randomRIO @Int (1, 1_000_000)
        SigRPC2 (ChangeMaster rsp) -> withResp rsp $ do
          cast @"log" $ Log ""
          put Master

r1 :: IO ()
r1 = do
  nodes <- forM [1 .. 4] $ \i -> do
    tc <- newTChanIO
    pure (NodeId i, tc)
  let nodeMap = Map.fromList nodes
  hhs@(h : hs) <- forM nodes $ \(nid, tc) -> do
    statusChan <- newMessageChan @SigStatus
    pure (NodeState nid (Map.delete nid nodeMap) tc, statusChan)

  logChan <- newMessageChan @SigLog

  forkIO $
    void $
      forever $ do
        forM_ hhs $ \(_, sv) -> do
          runWithServer @"status" sv t00

  forkIO $
    void $
      runWithServer @"log" logChan t0

  forkIO $
    void $
      runMetric @LogMet $
        runServerWithChan logChan log

  forkIO $
    void $
      runWithServer @"log" logChan $
        runServerWithChan (snd h) $
          runWithPeers' @"peer" (fst h) $
            runState Master t1

  forM_ hs $ \h' -> do
    forkIO $
      void $
        runWithServer @"log" logChan $
          runServerWithChan (snd h') $
            runWithPeers' @"peer" (fst h') $
              runState Slave t1

  forever $ do
    threadDelay 10_000_000
