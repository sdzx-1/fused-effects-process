{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Carrier.HasPeer
  ( module P,
    PeerState (..),
    runWithPeers,
  )
where

import Control.Carrier.State.Strict
  ( Algebra,
    StateC (..),
    evalState,
    get,
    put,
  )
import Control.Concurrent.STM
  ( atomically,
    newEmptyTMVarIO,
  )
import Control.Effect.HasPeer as P
import Control.Effect.Labelled
  ( Algebra (..),
    Labelled,
    runLabelled,
    type (:+:) (..),
  )
import Control.Monad (forM)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind (Type)
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.TypeLits (Symbol)
import Process.TChan (TChan, writeTChan)
import Process.Type
  ( NodeId,
    RespVal (..),
    Some,
    inject,
  )

type PeerState :: (Type -> Type) -> [Type] -> Type
data PeerState s ts = PeerState
  { nodeId :: NodeId,
    peers :: Map NodeId (TChan (Some s)),
    nodeChan :: TChan (Some s)
  }

newtype PeerActionC s ts m a = PeerActionC {unPeerActionC :: StateC (PeerState s ts) m a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance
  (Algebra sig m, MonadIO m) =>
  Algebra (PeerAction s ts :+: sig) (PeerActionC s ts m)
  where
  alg hdl sig ctx = PeerActionC $ case sig of
    L (Join nid tc) -> do
      ps@PeerState {peers} <- get @(PeerState s ts)
      put @(PeerState s ts) (ps {peers = Map.insert nid tc peers})
      pure ctx
    L (Leave nid) -> do
      ps@PeerState {peers} <- get @(PeerState s ts)
      put @(PeerState s ts) (ps {peers = Map.delete nid peers})
      pure ctx
    L PeerSize -> do
      PeerState {peers} <- get @(PeerState s ts)
      pure (Map.size peers <$ ctx)
    L (SendMessage nid t) -> do
      PeerState {peers} <- get @(PeerState s ts)
      case Map.lookup nid peers of
        Nothing -> do
          liftIO $ print $ "node id not found: " ++ show nid
          pure ctx
        Just tc -> do
          liftIO $ atomically $ writeTChan tc (inject t)
          pure ctx
    L (SendAllCall t) -> do
      PeerState {peers} <- get @(PeerState s ts)
      tmvs <- forM (Map.toList peers) $ \(idx, ch) -> do
        tmv <- liftIO newEmptyTMVarIO
        liftIO $ atomically $ writeTChan ch (inject (t $ RespVal tmv))
        pure (idx, tmv)
      pure (tmvs <$ ctx)
    L (SendAllCast t) -> do
      PeerState {peers} <- get @(PeerState s ts)
      Map.traverseWithKey (\_ ch -> liftIO $ atomically $ writeTChan ch (inject t)) peers
      pure ctx
    L GetChan -> do
      PeerState {nodeChan} <- get @(PeerState s ts)
      pure (nodeChan <$ ctx)
    L GetNodeId -> do
      PeerState {nodeId} <- get @(PeerState s ts)
      pure (nodeId <$ ctx)
    L GetPeersNodeId -> do
      PeerState {peers} <- get @(PeerState s ts)
      pure (Map.keys peers <$ ctx)
    R signa -> alg (unPeerActionC . hdl) (R signa) ctx
  {-# INLINE alg #-}

runWithPeers ::
  forall peerName s ts m a.
  MonadIO m =>
  PeerState s ts ->
  Labelled (peerName :: Symbol) (PeerActionC s ts) m a ->
  m a
runWithPeers ns f = evalState ns $ unPeerActionC $ runLabelled f
{-# INLINE runWithPeers #-}
