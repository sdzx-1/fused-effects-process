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

import Control.Algebra (type (:+:))
import Control.Carrier.HasPeer
  ( HasPeer,
    PeerState (..),
    callAll,
    callById,
    runWithPeers,
  )
import Control.Carrier.HasServer (HasServer, cast, runWithServer)
import Control.Carrier.Metric.IO
import Control.Carrier.Random.Gen
import Control.Carrier.State.Strict
  ( State,
    get,
    put,
    runState,
  )
import Control.Concurrent
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMVar (readTMVar)
import Control.Monad (forM, forM_, forever, void)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.Map as Map
import Process.TChan (newTChanIO)
import Process.TH
import Process.Type
import Process.Util
import System.Random (mkStdGen)
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
  [ "all_log",
    "all_all"
  ]

mkMetric
  "NodeMet"
  [ "all_a",
    "all_b",
    "all_c"
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
      inc all_all
      inc all_log
    SigLog2 Cal -> do
      val <- getVal all_log
      all <- getVal all_all
      liftIO $ print (val, all)
      putVal all_log 0

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
    Has (State Role :+: Random) sig m,
    Has (Metric NodeMet) sig m,
    HasServer "log" SigLog '[Log] sig m,
    HasPeer "peer" SigRPC '[CallMsg, ChangeMaster] sig m
  ) =>
  m ()
t1 = forever $ do
  inc all_a
  get @Role >>= \case
    Master -> do
      inc all_b
      res <- callAll @"peer" $ CallMsg
      vals <- forM res $ \(a, b) -> do
        val <- liftIO $ atomically $ readTMVar b
        pure (val, a)
      let mnid = snd $ maximum vals
      callById @"peer" mnid ChangeMaster
      put Slave
    Slave -> do
      inc all_c
      handleMsg @"peer" $ \case
        SigRPC1 (CallMsg rsp) -> withResp rsp $ do
          uniformR (1, 100_000)
        SigRPC2 (ChangeMaster rsp) -> withResp rsp $ do
          cast @"log" $ Log ""
          put Master

r1 :: IO ()
r1 = do
  nodes <- forM [1 .. 4] $ \i -> do
    tc <- newTChanIO
    pure (NodeId i, tc)
  let nodeMap = Map.fromList nodes
  (h : hs) <- forM nodes $ \(nid, tc) -> do
    pure (PeerState nid (Map.delete nid nodeMap) tc)

  logChan <- newMessageChan @SigLog

  forkIO
    . void
    $ runWithServer @"log" logChan t0

  forkIO
    . void
    . runMetric @LogMet
    $ runServerWithChan logChan log

  forkIO
    . void
    . runWithServer @"log" logChan
    . runWithPeers @"peer" h
    . runRandom (mkStdGen 1)
    . runMetric @NodeMet
    $ runState Master t1

  forM_ hs $ \h' ->
    do
      forkIO
        . void
        . runWithServer @"log" logChan
        . runWithPeers @"peer" h'
      . runRandom (mkStdGen 2)
      . runMetric @NodeMet
      $ runState Slave t1

  forever $ do
    threadDelay 10_000_000
