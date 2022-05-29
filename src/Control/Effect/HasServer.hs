{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Effect.HasServer
  ( HasServer,
    Request (..),
    call,
    cast,
    timeoutCall,
  )
where

import Control.Concurrent.STM (atomically, newEmptyTMVarIO, takeTMVar)
import Control.Effect.Labelled
  ( HasLabelled,
    sendLabelled,
  )
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind
  ( Type,
  )
import GHC.TypeLits
  ( Symbol,
  )
import Process.Type
  ( Elem,
    Elems,
    RespVal (..),
    ToList,
    ToSig,
  )
import System.Timeout (timeout)

type HasServer (serverName :: Symbol) s ts sig m =
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
  SendReq :: (ToSig t s) => t -> Request s ts m ()

sendReq ::
  forall serverName s ts sig m t.
  ( Elem serverName t ts,
    ToSig t s,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  t ->
  m ()
sendReq t = sendLabelled @serverName (SendReq t)
{-# INLINE sendReq #-}

call ::
  forall serverName s ts sig m e b.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  (RespVal b -> e) ->
  m b
call f = do
  mvar <- liftIO newEmptyTMVarIO
  sendReq @serverName (f $ RespVal mvar)
  liftIO $ atomically $ takeTMVar mvar
{-# INLINE call #-}

timeoutCall ::
  forall serverName s ts sig m e b.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  Int ->
  (RespVal b -> e) ->
  m (Maybe b)
timeoutCall tot f = do
  mvar <- liftIO newEmptyTMVarIO
  sendReq @serverName (f $ RespVal mvar)
  liftIO $ timeout tot $ atomically $ takeTMVar mvar
{-# INLINE timeoutCall #-}

cast ::
  forall serverName s ts sig m e.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  e ->
  m ()
cast f = do
  sendReq @serverName f
{-# INLINE cast #-}
