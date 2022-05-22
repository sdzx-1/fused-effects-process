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
import Process.TChan (newTChanIO)
import Process.TH (mkSigAndClass)
import Process.Type
import Process.Util
import System.Random

data Role = Master | Slave

data ChangeMaster where
  ChangeMaster :: RespVal () %1 -> ChangeMaster

data CallMsg where
  CallMsg :: RespVal Int %1 -> CallMsg

mkSigAndClass
  "SigRPC"
  [ ''CallMsg,
    ''ChangeMaster
  ]

t1 ::
  ( MonadIO m,
    Has (State Role) sig m,
    HasPeerGroup "peer" SigRPC '[CallMsg, ChangeMaster] sig m
  ) =>
  m ()
t1 = forever $ do
  get @Role >>= \case
    Master -> do
      liftIO $ threadDelay 1_000_00
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
          nid <- getNodeId @"peer"
          rv <- liftIO $ randomRIO @Int (10, 100)
          liftIO $ print (nid, rv)
          pure rv
        SigRPC2 (ChangeMaster rsp) -> withResp rsp $ do
          nid <- getNodeId @"peer"
          liftIO $ print $ show nid ++ " be master"
          put Master

r1 :: IO ()
r1 = do
  nodes <- forM [1 .. 10] $ \i -> do
    tc <- newTChanIO
    pure (NodeId i, tc)
  let nodeMap = Map.fromList nodes
  h : hs <- forM nodes $ \(nid, tc) -> do
    pure (NodeState nid (Map.delete nid nodeMap) tc)

  forkIO $
    void $
      runWithPeers' @"peer" h $ runState Master t1

  forM_ hs $ \h' -> do
    forkIO $
      void $
        runWithPeers' @"peer" h' $ runState Slave t1

  forever $ do
    threadDelay 10_000_000
