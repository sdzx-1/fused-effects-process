{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.HasPeerGroup where

import Control.Applicative
import Control.Carrier.State.Strict
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TMVar
import Control.Effect.Labelled
import Control.Monad
import Control.Monad.IO.Class
import Data.Kind
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.TypeLits
import Process.Timer
import Process.Type (Elem, Some, Sum, ToSig, inject)
import Unsafe.Coerce (unsafeCoerce)

newtype NodeID = NodeID Int deriving (Show, Eq, Ord)

---------------------------------------- api
-- peerJoin
-- peerLeave
-- callPeer :: NodeID -> Message -> m RespVal
-- callPeers :: Message -> m [RespVal]
-- castPeer :: NodeID -> Message -> m ()
-- castPeers :: Message -> m ()

data RespVal a where
  RespVal :: TMVar a -> RespVal a

type PeerAction :: (Type -> Type) -> [Type] -> (Type -> Type) -> Type -> Type
data PeerAction s ts m a where
  ------- action
  Join :: NodeID -> TChan (Sum s ts) -> PeerAction s ts m ()
  Leave :: NodeID -> PeerAction s ts m ()
  ------- messge
  SendMessage :: (ToSig t s) => NodeID -> t -> PeerAction s ts m ()
  SendAllCall :: (ToSig t s) => (RespVal b -> t) -> PeerAction s ts m [(NodeID, TMVar b)]
  SendAllCast :: (ToSig t s) => t -> PeerAction s ts m ()
  ------- chan
  GetChan :: PeerAction s ts m (TChan (Some s))

getChan ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  m (TChan (Some s))
getChan = sendLabelled @peerName GetChan

leave ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  NodeID ->
  m ()
leave i = sendLabelled @peerName (Leave i)

join ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  NodeID ->
  TChan (Sum s ts) ->
  m ()
join i t = sendLabelled @peerName (Join i t)

sendReq ::
  forall (peerName :: Symbol) s ts sig m t.
  ( Elem peerName t ts,
    ToSig t s,
    HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  NodeID ->
  t ->
  m ()
sendReq i t = sendLabelled @peerName (SendMessage i t)

callAll ::
  forall (peerName :: Symbol) s ts sig m t b.
  ( Elem peerName t ts,
    ToSig t s,
    HasLabelled peerName (PeerAction s ts) sig m,
    MonadIO m
  ) =>
  (RespVal b -> t) ->
  m [(NodeID, TMVar b)]
callAll t = do
  sendLabelled @peerName (SendAllCall t)

type NodeState :: (Type -> Type) -> [Type] -> Type
data NodeState s ts = NodeState
  { nodeId :: NodeID,
    peers :: Map NodeID (TChan (Sum s ts)),
    nodeChan :: TChan (Sum s ts)
  }

newtype PeerActionC s ts m a = PeerActionC {unPeerActionC :: StateC (NodeState s ts) m a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance
  (Algebra sig m, MonadIO m) =>
  Algebra (PeerAction s ts :+: sig) (PeerActionC s ts m)
  where
  alg hdl sig ctx = PeerActionC $ case sig of
    L (Join nid tc) -> do
      ps@NodeState {peers} <- get @(NodeState s ts)
      put (ps {peers = Map.insert nid tc peers})
      pure ctx
    L (Leave nid) -> do
      ps@NodeState {peers} <- get @(NodeState s ts)
      put (ps {peers = Map.delete nid peers})
      pure ctx
    L (SendMessage nid t) -> do
      ps@NodeState {peers} <- get @(NodeState s ts)
      case Map.lookup nid peers of
        Nothing -> do
          liftIO $ print $ "node id not found: " ++ show nid
          pure ctx
        Just tc -> do
          liftIO $ atomically $ writeTChan tc (inject t)
          pure ctx
    L (SendAllCall t) -> do
      ps@NodeState {peers} <- get @(NodeState s ts)
      tmvs <- forM (Map.toList peers) $ \(idx, ch) -> do
        tmv <- liftIO $ newEmptyTMVarIO
        liftIO $ atomically $ writeTChan ch (inject (t $ RespVal tmv))
        pure (idx, tmv)
      pure (tmvs <$ ctx)
    L (SendAllCast t) -> do
      ps@NodeState {peers} <- get @(NodeState s ts)
      Map.traverseWithKey (\_ ch -> liftIO $ atomically $ writeTChan ch (inject t)) peers
      pure ctx
    L GetChan -> do
      NodeState {nodeChan} <- get @(NodeState s ts)
      pure (unsafeCoerce nodeChan <$ ctx)
    R signa -> alg (unPeerActionC . hdl) (R signa) ctx

initNodeState :: NodeID -> IO (NodeState s ts)
initNodeState nid = do
  tc <- newTChanIO
  pure $ NodeState nid Map.empty tc

runWithPeers ::
  forall peerName s ts m a.
  MonadIO m =>
  NodeID ->
  Labelled (peerName :: Symbol) (PeerActionC s ts) m a ->
  m a
runWithPeers nid f = do
  ins <- liftIO $ initNodeState nid
  evalState @(NodeState s ts) ins $
    unPeerActionC $ runLabelled f

runWithPeers' ::
  forall peerName s ts m a.
  MonadIO m =>
  NodeState s ts ->
  Labelled (peerName :: Symbol) (PeerActionC s ts) m a ->
  m a
runWithPeers' ns f = do
  evalState ns $ unPeerActionC $ runLabelled f
