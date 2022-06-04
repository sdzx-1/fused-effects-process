{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.Effect.HasPeer
  ( HasPeer,
    PeerState (..),
    Peer,
    NodeID (..),
    addPeer,
    deletePeer,
    peerSize,
    getSelfNodeID,
    getSelfTQueue,
    getPeersNodeID,
    call,
    timeoutCall,
    cast,
    callAll,
    castAll,
    runWithPeers,
  )
where

import Control.Carrier.Lift (Algebra, Has, Lift, sendM)
import Control.Carrier.State.Church (StateC (..), runState)
import Control.Effect.Labelled
  ( Algebra (alg),
    HasLabelled,
    Labelled,
    runLabelled,
    sendLabelled,
    type (:+:) (..),
  )
import Control.Monad (forM)
import Control.Monad.Class.MonadSTM
  ( MonadSTM
      ( TQueue,
        atomically,
        writeTQueue
      ),
  )
import Control.Monad.Class.MonadSTM.Strict (StrictTMVar, newEmptyTMVarIO, takeTMVar)
import Control.Monad.Class.MonadTime (DiffTime)
import Control.Monad.Class.MonadTimer (MonadTimer (timeout))
import Control.Monad.IO.Class (MonadIO)
import Data.Kind (Type)
import qualified Data.Map as Map
import Data.Map.Strict (Map)
import GHC.TypeLits (Symbol)
import Process.Effect.Type (Elems, RespVal (..), Some, TMAP, ToList, ToSig, inject)

newtype NodeID = NodeID Int deriving (Show, Eq, Ord)

type PeerState ::
  ((Type -> Type) -> Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  Type
data PeerState s ts n = PeerState
  { nodeID :: NodeID,
    nodeTQueue :: TQueue n (Some n s),
    peerTQueues :: Map NodeID (TQueue n (Some n s))
  }

----------------------------------------------------------------

type HasPeer (name :: Symbol) s ts n sig m =
  ( Has (Lift n) sig m,
    Elems name (TMAP ts n) (ToList (s n)),
    HasLabelled name (Peer s (TMAP ts n) n) sig m
  )

----------------------------------------------------------------
type Peer ::
  ((Type -> Type) -> Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  (Type -> Type) ->
  Type ->
  Type
data Peer s ts n m a where
  ------------------------------------------------------------
  -- add node
  AddPeer :: NodeID -> TQueue n (Some n s) -> Peer s ts n m ()
  -- delete leave
  DeletePeer :: NodeID -> Peer s ts n m ()
  -- peer size
  PeerSize :: Peer s ts n m Int
  ------------------------------------------------------------
  -- get self NodeID
  GetSelfNodeID :: Peer s ts n m NodeID
  -- get self TQueue
  GetSelfTQueue :: Peer s ts n m (TQueue n (Some n s))
  -- get all peers NodeID
  GetPeersNodeID :: Peer s ts n m [NodeID]
  ------------------------------------------------------------
  -- call
  Call :: (ToSig t s n) => NodeID -> (RespVal n b -> t n) -> Peer s ts n m b
  -- timeoutCall
  TimeoutCall :: (ToSig t s n) => DiffTime -> NodeID -> (RespVal n b -> t n) -> Peer s ts n m (Maybe b)
  -- cast
  Cast :: (ToSig t s n) => NodeID -> t n -> Peer s ts n m ()
  ------------------------------------------------------------
  -- call the same message to all node
  CallAll :: (ToSig t s n) => (RespVal n b -> t n) -> Peer s ts n m [(NodeID, StrictTMVar n b)]
  -- cast the same message to all node
  CastAll :: (ToSig t s n) => t n -> Peer s ts n m ()

----------------------------------------------------------------
addPeer ::
  forall (name :: Symbol) s ts n sig m.
  HasLabelled name (Peer s ts n) sig m =>
  NodeID ->
  TQueue n (Some n s) ->
  m ()
addPeer nid tq = sendLabelled @name (AddPeer nid tq)
{-# INLINE addPeer #-}

deletePeer ::
  forall (name :: Symbol) s ts n sig m.
  HasLabelled name (Peer s ts n) sig m =>
  NodeID ->
  m ()
deletePeer nid = sendLabelled @name (DeletePeer nid)
{-# INLINE deletePeer #-}

peerSize ::
  forall (name :: Symbol) s ts n sig m.
  HasLabelled name (Peer s ts n) sig m =>
  m Int
peerSize = sendLabelled @name PeerSize
{-# INLINE peerSize #-}

----------------------------------------------------------------
getSelfNodeID ::
  forall (name :: Symbol) s ts n sig m.
  HasLabelled name (Peer s ts n) sig m =>
  m NodeID
getSelfNodeID = sendLabelled @name GetSelfNodeID
{-# INLINE getSelfNodeID #-}

getSelfTQueue ::
  forall (name :: Symbol) s ts n sig m.
  HasLabelled name (Peer s ts n) sig m =>
  m (TQueue n (Some n s))
getSelfTQueue = sendLabelled @name GetSelfTQueue
{-# INLINE getSelfTQueue #-}

getPeersNodeID ::
  forall (name :: Symbol) s ts n sig m.
  HasLabelled name (Peer s ts n) sig m =>
  m [NodeID]
getPeersNodeID = sendLabelled @name GetPeersNodeID
{-# INLINE getPeersNodeID #-}

----------------------------------------------------------------

call ::
  forall (name :: Symbol) s ts n sig m t b.
  ( ToSig t s n,
    HasLabelled name (Peer s ts n) sig m
  ) =>
  NodeID ->
  (RespVal n b -> t n) ->
  m b
call nid fun = sendLabelled @name (Call nid fun)
{-# INLINE call #-}

timeoutCall ::
  forall (name :: Symbol) s ts n sig m t b.
  ( ToSig t s n,
    HasLabelled name (Peer s ts n) sig m
  ) =>
  DiffTime ->
  NodeID ->
  (RespVal n b -> t n) ->
  m (Maybe b)
timeoutCall dt nid fun = sendLabelled @name (TimeoutCall dt nid fun)
{-# INLINE timeoutCall #-}

cast ::
  forall (name :: Symbol) s ts n sig m t.
  ( ToSig t s n,
    HasLabelled name (Peer s ts n) sig m
  ) =>
  NodeID ->
  t n ->
  m ()
cast nid msg = sendLabelled @name (Cast nid msg)
{-# INLINE cast #-}

----------------------------------------------------------------

callAll ::
  forall (name :: Symbol) s ts n sig m t b.
  ( ToSig t s n,
    HasLabelled name (Peer s ts n) sig m
  ) =>
  (RespVal n b -> t n) ->
  m [(NodeID, StrictTMVar n b)]
callAll fun = sendLabelled @name (CallAll fun)
{-# INLINE callAll #-}

castAll ::
  forall (name :: Symbol) s ts n sig m t.
  ( ToSig t s n,
    HasLabelled name (Peer s ts n) sig m
  ) =>
  t n ->
  m ()
castAll msg = sendLabelled @name (CastAll msg)
{-# INLINE castAll #-}

----------------------------------------------------------------

type PeerC ::
  ((Type -> Type) -> Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  (Type -> Type) ->
  Type ->
  Type
newtype PeerC s ts n m a = PeerC
  { unPeerC :: StateC (PeerState s ts n) m a
  }
  deriving (Functor, Applicative, Monad, MonadIO)

instance
  ( MonadSTM n,
    MonadTimer n,
    Has (Lift n) sig m
  ) =>
  Algebra (Peer s ts n :+: sig) (PeerC s ts n m)
  where
  alg hdl sig ctx = PeerC $ case sig of
    ------------------------------------------------------------
    L (AddPeer nid tq) -> StateC $ \k ps@PeerState {peerTQueues} -> do
      k (ps {peerTQueues = Map.insert nid tq peerTQueues}) ctx
    L (DeletePeer nid) -> StateC $ \k ps@PeerState {peerTQueues} -> do
      k (ps {peerTQueues = Map.delete nid peerTQueues}) ctx
    L PeerSize -> StateC $ \k ps@PeerState {peerTQueues} -> do
      k ps (Map.size peerTQueues <$ ctx)
    ------------------------------------------------------------
    L GetSelfNodeID -> StateC $ \k ps@PeerState {nodeID} -> do
      k ps (nodeID <$ ctx)
    L GetSelfTQueue -> StateC $ \k ps@PeerState {nodeTQueue} -> do
      k ps (nodeTQueue <$ ctx)
    L GetPeersNodeID -> StateC $ \k ps@PeerState {peerTQueues} -> do
      k ps (Map.keys peerTQueues <$ ctx)
    ------------------------------------------------------------
    L (Call nid fun) -> StateC $ \k ps@PeerState {peerTQueues} -> do
      case Map.lookup nid peerTQueues of
        Nothing -> k ps (error "node id not exist" <$ ctx)
        Just tq -> do
          res <- sendM @n $ do
            tmvar <- newEmptyTMVarIO
            atomically $ writeTQueue tq (inject (fun $ RespVal tmvar))
            atomically $ takeTMVar tmvar
          k ps (res <$ ctx)
    L (TimeoutCall dt nid fun) -> StateC $ \k ps@PeerState {peerTQueues} -> do
      case Map.lookup nid peerTQueues of
        Nothing -> k ps (error "node id not exist" <$ ctx)
        Just tq -> do
          res <- sendM @n $ do
            tmvar <- newEmptyTMVarIO
            atomically $ writeTQueue tq (inject (fun $ RespVal tmvar))
            timeout dt $ atomically $ takeTMVar tmvar
          k ps (res <$ ctx)
    L (Cast nid msg) -> StateC $ \k ps@PeerState {peerTQueues} -> do
      case Map.lookup nid peerTQueues of
        Nothing -> k ps (error "node id not exist" <$ ctx)
        Just tq -> do
          sendM @n $ atomically $ writeTQueue tq (inject msg)
          k ps ctx
    ------------------------------------------------------------
    L (CallAll fun) -> StateC $ \k ps@PeerState {peerTQueues} -> do
      pars <- forM (Map.toList peerTQueues) $ \(idx, tq) -> sendM @n $ do
        tmvar <- newEmptyTMVarIO
        atomically $ writeTQueue tq $ inject $ fun $ RespVal tmvar
        pure (idx, tmvar)
      k ps (pars <$ ctx)
    L (CastAll msg) -> StateC $ \k ps@PeerState {peerTQueues} -> do
      Map.traverseWithKey
        (\_ tq -> sendM @n $ atomically $ writeTQueue tq (inject msg))
        peerTQueues
      k ps ctx
    ------------------------------------------------------------
    R signa -> alg (unPeerC . hdl) (R signa) ctx
  {-# INLINE alg #-}

----------------------------------------------------------------
runWithPeers ::
  forall (name :: Symbol) n s ts m a.
  Applicative m =>
  PeerState s ts n ->
  Labelled name (PeerC s ts n) m a ->
  m (PeerState s ts n, a)
runWithPeers ps = runState (curry pure) ps . unPeerC . runLabelled
{-# INLINE runWithPeers #-}
