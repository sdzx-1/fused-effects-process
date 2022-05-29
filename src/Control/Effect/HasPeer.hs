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

module Control.Effect.HasPeer
  ( HasPeer,
    PeerAction (..),
    getPeersNodeId,
    getNodeId,
    getChan,
    leave,
    join,
    peerSize,
    callById,
    castById,
    callAll,
  )
where

import Control.Concurrent.STM
  ( TMVar,
    atomically,
    newEmptyTMVarIO,
    takeTMVar,
  )
import Control.Effect.Labelled
  ( HasLabelled,
    sendLabelled,
  )
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind (Type)
import GHC.TypeLits (Symbol)
import Process.TChan (TChan)
import Process.Type
  ( Elem,
    Elems,
    NodeId,
    RespVal (..),
    Some,
    ToList,
    ToSig,
  )

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
