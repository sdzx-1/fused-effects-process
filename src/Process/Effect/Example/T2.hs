{-# LANGUAGE BlockArguments #-}
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

module Process.Effect.Example.T2 where

import Control.Algebra
import Control.Carrier.Lift
import Control.Carrier.Metric.Pure
import Control.Carrier.Random.Gen
import Control.Carrier.State.Strict
import Control.Effect.Metric
import Control.Monad (forM, forM_, void)
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadSTM hiding (readTMVar)
import Control.Monad.Class.MonadSTM.Strict
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (runSimTrace, selectTraceEventsSay)
import Data.Kind (Type)
import qualified Data.Map as Map
import Process.Effect.HasMessageChan
import Process.Effect.HasPeer as P
import Process.Effect.HasServer as S
import Process.Effect.TH
import Process.Effect.Type
import Process.Effect.Utils
import Process.TH hiding (mkSigAndClass)
import System.Random (mkStdGen)
import Prelude hiding (log)

data Role = Master | Slave deriving (Show)

data ChangeMaster (n :: Type -> Type) where
  ChangeMaster :: RespVal n () %1 -> ChangeMaster n

data CallMsg (n :: Type -> Type) where
  CallMsg :: RespVal n Int %1 -> CallMsg n

data Log (n :: Type -> Type) where
  Log :: String -> Log n

data Cal (n :: Type -> Type) where
  Cal :: Cal n

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
  forall n sig m.
  ( MonadSay n,
    MonadSTM n,
    Has (Metric LogMet) sig m,
    HasMessageChan "log" SigLog n sig m
  ) =>
  m ()
log = forever $ do
  withMessageChan @"log" \case
    SigLog1 (Log s) -> do
      sendM @n $ say s
      inc all_all
      inc all_log
    SigLog2 Cal -> do
      val <- getVal all_log
      all <- getVal all_all
      sendM @n $ say $ show (val, all)
      putVal all_log 0

t0 ::
  forall n sig m.
  ( MonadDelay n,
    HasServer "log" SigLog '[Cal] n sig m
  ) =>
  m ()
t0 = forever $ do
  S.cast @"log" Cal
  sendM @n $ threadDelay 1

t1 ::
  forall n sig m.
  ( MonadSTM n,
    MonadDelay n,
    Has (State Role) sig m,
    Has (Metric NodeMet :+: Random) sig m,
    HasServer "log" SigLog '[Log] n sig m,
    HasPeer "peer" SigRPC '[CallMsg, ChangeMaster] n sig m
  ) =>
  m ()
t1 = forever $ do
  inc all_a
  get @Role >>= \case
    Master -> do
      inc all_b
      res <- P.callAll @"peer" $ CallMsg
      vals <- forM res $ \(a, b) -> do
        val <- sendM @n $ atomically $ readTMVar b
        pure (val, a)
      let mnid = snd $ maximum vals
      P.call @"peer" mnid ChangeMaster
      put Slave
    Slave -> do
      inc all_c
      handlePeerMsg @"peer" \case
        SigRPC1 (CallMsg rsp) ->
          withResp rsp $ do
            sendM @n $ threadDelay 0.4
            uniformR (1, 100_000)
        SigRPC2 (ChangeMaster rsp) ->
          withResp rsp $ do
            nid <- getSelfNodeID @"peer"
            S.cast @"log" $ Log $ show nid
            put Master

r0 ::
  forall n.
  ( MonadSay n,
    MonadSTM n,
    MonadFork n,
    MonadDelay n,
    MonadTimer n,
    MonadTime n,
    Algebra (Lift n) n
  ) =>
  n ()
r0 = do
  nodes <- forM [1 .. 4] $ \i -> do
    tc <- newMessageChan @n @SigRPC
    pure (NodeID i, tc)
  let nodeMap = Map.fromList nodes

  res <- forM nodes $ \(nid, tc) -> do
    pure (PeerState nid tc (Map.delete nid nodeMap))
  case res of
    (h : hs) -> do
      logChan <- newMessageChan @n @SigLog

      forkIO
        . void
        $ runWithServer @"log" logChan t0

      forkIO
        . void
        . runMetric @LogMet
        $ runServer @"log" logChan log

      forkIO
        . void
        . runWithServer @"log" logChan
        . runWithPeers @"peer" h
        . runRandom (mkStdGen 1)
        . runMetric @NodeMet
        $ runState Master t1

      forM_ hs $ \h' -> do
        forkIO
          . void
          . runWithServer @"log" logChan
          . runWithPeers @"peer" h'
          . runRandom (mkStdGen 2)
          . runMetric @NodeMet
          $ runState Slave t1
    _ -> pure ()

  threadDelay 5

r1 = r0 :: IO ()

r2 = selectTraceEventsSay $ runSimTrace r0

-- >>> r2
-- ["(0,0)","NodeID 4","NodeID 1","(2,2)","NodeID 3","NodeID 4","(2,4)","NodeID 3","NodeID 2","NodeID 4","(3,7)","NodeID 3","NodeID 4","(2,9)","NodeID 2","NodeID 1","NodeID 3"]
