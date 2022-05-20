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
{-# OPTIONS_GHC -Wno-unused-matches #-}

module Raft.T where

import Control.Algebra (Has, type (:+:))
import Control.Applicative (Alternative ((<|>)))
import Control.Carrier.Error.Either
  ( Error,
    catchError,
    runError,
    throwError,
  )
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
import Control.Effect.Optics (use, (.=))
import Control.Monad (forM, forM_, forever, void)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Typeable as T
import Process.HasPeerGroup
  ( HasPeerGroup,
    NodeId (NodeId),
    NodeState (..),
    callAll,
    getChan,
    runWithPeers,
    runWithPeers',
  )
import Process.HasWorkGroup hiding (callAll)
import Process.Metric (Metric, inc, putVal, runMetric)
import Process.TChan (TChan, newTChanIO, readTChan)
import Process.TH (mkSigAndClass)
import Process.Timer (Timeout, newTimeout, waitTimeout)
import Process.Type
import Process.Type (RespVal (RespVal), Some (..))
import Process.Util
import Raft.Metric
import System.Random

data Role = Master | Slave

data CastMsg where
  CastMsg :: Int -> CastMsg

data ChangeMaster = ChangeMaster

data CallMsg where
  CallMsg :: RespVal (Either ChangeMaster Int) %1 -> CallMsg

mkSigAndClass
  "SigRPC"
  [ ''CastMsg,
    ''CallMsg
  ]

t1 ::
  ( MonadIO m,
    Has (State Role) sig m,
    HasPeerGroup "peer" SigRPC '[CastMsg, CallMsg] sig m
  ) =>
  m ()
t1 = forever $ do
  liftIO $ threadDelay 1_000_000
  get @Role >>= \case
    Master -> do
      res <- callAll @"peer" $ CallMsg
      forM_ res $ \(a, b) -> do
        val <- liftIO $ atomically $ readTMVar b
        case val of
          Left ChangeMaster -> do
            put Slave
          Right val -> liftIO $ print $ show a ++ " resp val " ++ show val
    Slave -> do
      chan <- getChan @"peer"
      Some tc <- liftIO $ atomically $ readTChan chan
      case tc of
        SigRPC1 (CastMsg i) -> liftIO $ do
          print "receive master cast msg"
          print i
        SigRPC2 (CallMsg rsp) -> withResp rsp $ do
          liftIO $ print "receive master call msg"
          ri <- liftIO $ randomRIO @Int (10, 100)
          liftIO $ print $ "response val is " ++ show ri
          if ri > 70
            then do
              liftIO $ print ".................."
              put Master
              pure (Left ChangeMaster)
            else do
              pure (Right ri)

r1 :: IO ()
r1 = do
  nodes <- forM [1 .. 2] $ \i -> do
    tc <- newTChanIO
    pure (NodeId i, tc)
  let nodeMap = Map.fromList nodes
  [a, b] <- forM nodes $ \(nid, tc) -> do
    pure (NodeState nid (Map.delete nid nodeMap) tc)

  forkIO $
    void $
      runWithPeers' @"peer" a $ runState Master $ t1

  forkIO $
    void $
      runWithPeers' @"peer" b $ runState Slave $ t1

  forever $ do
    threadDelay 10_000_000
