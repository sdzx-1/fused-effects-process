{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Effect.HasGroup
  ( HasGroup,
    Request (..),
    sendAllCall,
    sendAllCast,
    callById,
    castById,
    callAll,
    castAll,
    mcall,
    mcast,
    timeoutCallAll,
  )
where

import Control.Concurrent
  ( MVar,
    newEmptyMVar,
    takeMVar,
  )
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
import Data.Traversable (for)
import GHC.TypeLits (Symbol)
import Process.Type
  ( Elem,
    Elems,
    NodeId,
    RespVal (..),
    ToList,
    ToSig,
  )
import System.Timeout (timeout)

type HasGroup (serverName :: Symbol) s ts sig m =
  ( Elems serverName ts (ToList s),
    HasLabelled serverName (Request s ts) sig m
  )

type Request ::
  (Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  Type ->
  Type
data Request s ts m a where
  SendReq :: (ToSig t s) => NodeId -> t -> Request s ts m ()
  SendAllCall :: (ToSig t s) => (RespVal b -> t) -> Request s ts m [(NodeId, TMVar b)]
  SendAllCast :: (ToSig t s) => t -> Request s ts m ()

sendReq ::
  forall (serverName :: Symbol) s ts sig m t.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m
  ) =>
  NodeId ->
  t ->
  m ()
sendReq i t = sendLabelled @serverName (SendReq i t)
{-# INLINE sendReq #-}

sendAllCall ::
  forall (serverName :: Symbol) s ts sig m t b.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m
  ) =>
  (RespVal b -> t) ->
  m [(NodeId, TMVar b)]
sendAllCall t = sendLabelled @serverName (SendAllCall t)
{-# INLINE sendAllCall #-}

sendAllCast ::
  forall (serverName :: Symbol) s ts sig m t.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m
  ) =>
  t ->
  m ()
sendAllCast t = sendLabelled @serverName (SendAllCast t)
{-# INLINE sendAllCast #-}

callById ::
  forall serverName s ts sig m e b.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  NodeId ->
  (RespVal b -> e) ->
  m b
callById i f = do
  mvar <- liftIO newEmptyTMVarIO
  sendReq @serverName i (f $ RespVal mvar)
  liftIO $ atomically $ takeTMVar mvar
{-# INLINE callById #-}

callAll ::
  forall (serverName :: Symbol) s ts sig m t b.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  (RespVal b -> t) ->
  m [b]
callAll t = do
  vs <- sendLabelled @serverName (SendAllCall t)
  mapM (liftIO . atomically . takeTMVar . snd) vs
{-# INLINE callAll #-}

timeoutCallAll ::
  forall (serverName :: Symbol) s ts sig m t b.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  Int ->
  (RespVal b -> t) ->
  m (Maybe [b])
timeoutCallAll tot t = do
  vs <- sendLabelled @serverName (SendAllCall t)
  liftIO $ timeout tot $ mapM (atomically . takeTMVar . snd) vs
{-# INLINE timeoutCallAll #-}

mcall ::
  forall serverName s ts sig m e b.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  [NodeId] ->
  (MVar b -> e) ->
  m [b]
mcall is f = do
  for is $ \idx -> do
    mvar <- liftIO newEmptyMVar
    _ <- sendReq @serverName idx (f mvar)
    liftIO $ takeMVar mvar
{-# INLINE mcall #-}

castById ::
  forall serverName s ts sig m e.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  NodeId ->
  e ->
  m ()
castById i f = do
  sendReq @serverName i f
{-# INLINE castById #-}

castAll ::
  forall (serverName :: Symbol) s ts sig m t.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  t ->
  m ()
castAll t = sendLabelled @serverName (SendAllCast t)
{-# INLINE castAll #-}

mcast ::
  forall serverName s ts sig m e.
  ( Elem serverName e ts,
    ToSig e s,
    HasLabelled serverName (Request s ts) sig m,
    MonadIO m
  ) =>
  [NodeId] ->
  e ->
  m ()
mcast is f = mapM_ (\x -> castById @serverName x f) is
{-# INLINE mcast #-}
