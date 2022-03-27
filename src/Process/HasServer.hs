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

module Process.HasServer where

import Control.Carrier.Error.Either
  ( Algebra,
    Has,
  )
import Control.Carrier.Reader
  ( Algebra,
    Has,
    Reader,
    ReaderC (..),
    ask,
    runReader,
  )
import Control.Concurrent
  ( MVar,
    newEmptyMVar,
    takeMVar,
  )
import Control.Concurrent.MVar (putMVar)
import Control.Concurrent.STM (atomically)
import Control.Effect.Labelled
  ( Algebra (..),
    Has,
    HasLabelled,
    Labelled,
    runLabelled,
    sendLabelled,
    type (:+:) (..),
  )
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind
  ( Constraint,
    Type,
  )
import GHC.TypeLits
  ( ErrorMessage
      ( ShowType,
        Text,
        (:<>:)
      ),
    Symbol,
    TypeError,
  )
import Process.TChan
import Process.Type
  ( Elem,
    Elems,
    RespVal (..),
    Some (..),
    Sum,
    ToList,
    ToSig,
    inject,
  )
import System.Timeout (timeout)
import Unsafe.Coerce (unsafeCoerce)

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
  mvar <- liftIO newEmptyMVar
  sendReq @serverName (f $ RespVal mvar)
  liftIO $ takeMVar mvar

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
  mvar <- liftIO newEmptyMVar
  sendReq @serverName (f $ RespVal mvar)
  liftIO $ timeout tot $ takeMVar mvar

cast ::
  forall serverName s ts sig m e b.
  ( Elem serverName e ts,
    ToSig e s,
    MonadIO m,
    HasLabelled (serverName :: Symbol) (Request s ts) sig m
  ) =>
  e ->
  m ()
cast f = do
  -- liftIO $ putStrLn "send cast"
  sendReq @serverName f

newtype RequestC s ts m a = RequestC {unRequestC :: ReaderC (TChan (Sum s ts)) m a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m) => Algebra (Request s ts :+: sig) (RequestC s ts m) where
  alg hdl sig ctx = RequestC $
    ReaderC $ \c -> case sig of
      L (SendReq t) -> do
        liftIO $ atomically $ writeTChan c (inject t)
        pure ctx
      R signa -> alg (runReader c . unRequestC . hdl) signa ctx

-- client
runWithServer ::
  forall serverName s ts m a.
  TChan (Some s) ->
  Labelled (serverName :: Symbol) (RequestC s ts) m a ->
  m a
runWithServer chan f =
  runReader (unsafeCoerce chan) $ unRequestC $ runLabelled f
