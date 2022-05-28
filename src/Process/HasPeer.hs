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

module Process.HasPeer where

import Control.Carrier.State.Strict
  ( Algebra,
    StateC (..),
    evalState,
    get,
    put,
  )
import Control.Concurrent.STM
  ( TMVar,
    atomically,
    newEmptyTMVarIO,
    takeTMVar,
  )
import Control.Effect.Labelled
  ( Algebra (..),
    HasLabelled,
    Labelled,
    runLabelled,
    sendLabelled,
    type (:+:) (..),
  )
import Control.Monad (forM)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind (Type)
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.TypeLits (Symbol)
import Process.TChan (TChan, newTChanIO, writeTChan)
import Process.Type
  ( Elem,
    Elems,
    NodeId,
    RespVal (..),
    Some,
    ToList,
    ToSig,
    inject,
  )

---------------------------------------- api
-- peerJoin
-- peerLeave
-- callPeer :: NodeId -> Message -> m RespVal

-- callPeers :: Message -> m [RespVal]
-- castPeer :: NodeId -> Message -> m ()
-- castPeers :: Message -> m ()

type HasPeer (peerName :: Symbol) s ts sig m =
  ( Elems peerName ts (ToList s),
    HasLabelled peerName (PeerAction s ts) sig m
  )

type PeerAction :: (Type -> Type) -> [Type] -> (Type -> Type) -> Type -> Type
data PeerAction s ts m a where
  ------- action
  Join :: NodeId -> TChan (Some s) -> PeerAction s ts m ()
  Leave :: NodeId -> PeerAction s ts m ()
  PeerSize :: PeerAction s ts m Int
  ------- info
  GetNodeId :: PeerAction s ts m NodeId
  GetPeersNodeId :: PeerAction s ts m [NodeId]
  ------- messge
  SendMessage :: (ToSig t s) => NodeId -> t -> PeerAction s ts m ()
  SendAllCall :: (ToSig t s) => (RespVal b -> t) -> PeerAction s ts m [(NodeId, TMVar b)]
  SendAllCast :: (ToSig t s) => t -> PeerAction s ts m ()
  ------- chan
  GetChan :: PeerAction s ts m (TChan (Some s))

getPeersNodeId ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  m [NodeId]
getPeersNodeId = sendLabelled @peerName GetPeersNodeId
{-# INLINE getPeersNodeId #-}

getNodeId ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  m NodeId
getNodeId = sendLabelled @peerName GetNodeId
{-# INLINE getNodeId #-}

getChan ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  m (TChan (Some s))
getChan = sendLabelled @peerName GetChan
{-# INLINE getChan #-}

leave ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  NodeId ->
  m ()
leave i = sendLabelled @peerName (Leave i)
{-# INLINE leave #-}

join ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  NodeId ->
  TChan (Some s) ->
  m ()
join i t = sendLabelled @peerName (Join i t)
{-# INLINE join #-}

peerSize ::
  forall (peerName :: Symbol) s ts sig m.
  ( HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  m Int
peerSize = sendLabelled @peerName PeerSize
{-# INLINE peerSize #-}

sendReq ::
  forall (peerName :: Symbol) s ts sig m t.
  ( Elem peerName t ts,
    ToSig t s,
    HasLabelled peerName (PeerAction s ts) sig m
  ) =>
  NodeId ->
  t ->
  m ()
sendReq i t = sendLabelled @peerName (SendMessage i t)
{-# INLINE sendReq #-}

callById ::
  forall peerName s ts sig m e b.
  ( Elem peerName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (peerName :: Symbol) (PeerAction s ts) sig m
  ) =>
  NodeId ->
  (RespVal b -> e) ->
  m b
callById i f = do
  mvar <- liftIO newEmptyTMVarIO
  sendReq @peerName i (f $ RespVal mvar)
  liftIO $ atomically $ takeTMVar mvar
{-# INLINE callById #-}

castById ::
  forall peerName s ts sig m e.
  ( Elem peerName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (peerName :: Symbol) (PeerAction s ts) sig m
  ) =>
  NodeId ->
  e ->
  m ()
castById = sendReq @peerName
{-# INLINE castById #-}

callAll ::
  forall (peerName :: Symbol) s ts sig m t b.
  ( Elem peerName t ts,
    ToSig t s,
    HasLabelled peerName (PeerAction s ts) sig m,
    MonadIO m
  ) =>
  (RespVal b -> t) ->
  m [(NodeId, TMVar b)]
callAll t = sendLabelled @peerName (SendAllCall t)
{-# INLINE callAll #-}

type NodeState :: (Type -> Type) -> [Type] -> Type
data NodeState s ts = NodeState
  { nodeId :: NodeId,
    peers :: Map NodeId (TChan (Some s)),
    nodeChan :: TChan (Some s)
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
      put @(NodeState s ts) (ps {peers = Map.insert nid tc peers})
      pure ctx
    L (Leave nid) -> do
      ps@NodeState {peers} <- get @(NodeState s ts)
      put @(NodeState s ts) (ps {peers = Map.delete nid peers})
      pure ctx
    L PeerSize -> do
      NodeState {peers} <- get @(NodeState s ts)
      pure (Map.size peers <$ ctx)
    L (SendMessage nid t) -> do
      NodeState {peers} <- get @(NodeState s ts)
      case Map.lookup nid peers of
        Nothing -> do
          liftIO $ print $ "node id not found: " ++ show nid
          pure ctx
        Just tc -> do
          liftIO $ atomically $ writeTChan tc (inject t)
          pure ctx
    L (SendAllCall t) -> do
      NodeState {peers} <- get @(NodeState s ts)
      tmvs <- forM (Map.toList peers) $ \(idx, ch) -> do
        tmv <- liftIO newEmptyTMVarIO
        liftIO $ atomically $ writeTChan ch (inject (t $ RespVal tmv))
        pure (idx, tmv)
      pure (tmvs <$ ctx)
    L (SendAllCast t) -> do
      NodeState {peers} <- get @(NodeState s ts)
      Map.traverseWithKey (\_ ch -> liftIO $ atomically $ writeTChan ch (inject t)) peers
      pure ctx
    L GetChan -> do
      NodeState {nodeChan} <- get @(NodeState s ts)
      pure (nodeChan <$ ctx)
    L GetNodeId -> do
      NodeState {nodeId} <- get @(NodeState s ts)
      pure (nodeId <$ ctx)
    L GetPeersNodeId -> do
      NodeState {peers} <- get @(NodeState s ts)
      pure (Map.keys peers <$ ctx)
    R signa -> alg (unPeerActionC . hdl) (R signa) ctx
  {-# INLINE alg #-}

initNodeState :: NodeId -> IO (NodeState s ts)
initNodeState nid = do
  NodeState nid Map.empty <$> newTChanIO
{-# INLINE initNodeState #-}

runWithPeers ::
  forall peerName s ts m a.
  MonadIO m =>
  NodeId ->
  Labelled (peerName :: Symbol) (PeerActionC s ts) m a ->
  m a
runWithPeers nid f = do
  ins <- liftIO $ initNodeState nid
  evalState @(NodeState s ts) ins $
    unPeerActionC $ runLabelled f
{-# INLINE runWithPeers #-}

runWithPeers' ::
  forall peerName s ts m a.
  MonadIO m =>
  NodeState s ts ->
  Labelled (peerName :: Symbol) (PeerActionC s ts) m a ->
  m a
runWithPeers' ns f = evalState ns $ unPeerActionC $ runLabelled f
{-# INLINE runWithPeers' #-}
