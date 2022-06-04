{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.Effect.HasServer
  ( HasServer,
    call,
    cast,
    timeoutCall,
    runWithServer,
  )
where

import Control.Algebra (Algebra (..), type (:+:) (..))
import Control.Carrier.Error.Either
  ( Has,
  )
import Control.Carrier.Lift (Lift (..), sendM)
import Control.Carrier.Reader
  ( ReaderC (..),
    runReader,
  )
import Control.Effect.Labelled
  ( HasLabelled,
    Labelled,
    runLabelled,
    sendLabelled,
  )
import Control.Monad.Class.MonadSTM
  ( MonadSTM
      ( TQueue,
        atomically,
        writeTQueue
      ),
  )
import Control.Monad.Class.MonadSTM.Strict (newEmptyTMVarIO, takeTMVar)
import Control.Monad.Class.MonadTime (DiffTime)
import Control.Monad.Class.MonadTimer
  ( MonadTimer (timeout),
  )
import Control.Monad.IO.Class (MonadIO)
import Data.Kind
  ( Type,
  )
import GHC.TypeLits
  ( Symbol,
  )
import Process.Effect.Type
  ( Elem,
    Elems,
    RespVal (..),
    Some,
    TMAP,
    ToList,
    ToSig,
    inject,
  )

type HasServer (serverName :: Symbol) s ts n sig m =
  ( Has (Lift n) sig m,
    Elems serverName (TMAP ts n) (ToList (s n)),
    HasLabelled serverName (Request s (TMAP ts n) n) sig m
  )

type Request ::
  ((Type -> Type) -> Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  (Type -> Type) ->
  Type ->
  Type
data Request s ts n m a where
  Call ::
    (ToSig t s n) =>
    (RespVal n b -> t n) ->
    Request s ts n m b
  Cast ::
    (ToSig t s n) =>
    t n ->
    Request s ts n m ()
  TimeoutCall ::
    (ToSig t s n) =>
    DiffTime ->
    (RespVal n b -> t n) ->
    Request s ts n m (Maybe b)

call ::
  forall serverName s ts n sig m e b.
  ( ToSig e s n,
    Elem serverName (e n) ts,
    HasLabelled (serverName :: Symbol) (Request s ts n) sig m
  ) =>
  (RespVal n b -> e n) ->
  m b
call f = sendLabelled @serverName (Call f)
{-# INLINE call #-}

cast ::
  forall serverName s ts n sig m e.
  ( ToSig e s n,
    Elem serverName (e n) ts,
    HasLabelled (serverName :: Symbol) (Request s ts n) sig m
  ) =>
  e n ->
  m ()
cast f = sendLabelled @serverName (Cast f)
{-# INLINE cast #-}

timeoutCall ::
  forall serverName s ts n sig m e b.
  ( ToSig e s n,
    Elem serverName (e n) ts,
    HasLabelled (serverName :: Symbol) (Request s ts n) sig m
  ) =>
  DiffTime ->
  (RespVal n b -> e n) ->
  m (Maybe b)
timeoutCall time f = sendLabelled @serverName (TimeoutCall time f)
{-# INLINE timeoutCall #-}

type RequestC ::
  ((Type -> Type) -> Type -> Type) ->
  [Type] ->
  (Type -> Type) ->
  (Type -> Type) ->
  Type ->
  Type
newtype RequestC s ts n m a = RequestC
  { unRequestC ::
      ReaderC (TQueue n (Some n s)) m a
  }
  deriving (Functor, Applicative, Monad, MonadIO)

instance
  ( MonadSTM n,
    MonadTimer n,
    Has (Lift n) sig m
  ) =>
  Algebra (Request s ts n :+: sig) (RequestC s ts n m)
  where
  alg hdl sig ctx = RequestC $
    ReaderC $ \c -> case sig of
      L (Call f) -> do
        val <- sendM @n $ do
          tmvar <- newEmptyTMVarIO
          atomically $ writeTQueue c (inject (f $ RespVal tmvar))
          atomically $ takeTMVar tmvar
        pure (val <$ ctx)
      L (Cast f) -> do
        sendM @n $ atomically $ writeTQueue c (inject f)
        pure ctx
      L (TimeoutCall i f) -> do
        val <- sendM @n $ do
          tmvar <- newEmptyTMVarIO
          atomically $ writeTQueue c (inject (f $ RespVal tmvar))
          timeout i $ atomically $ takeTMVar tmvar
        pure (val <$ ctx)
      R signa -> alg (runReader c . unRequestC . hdl) signa ctx
  {-# INLINE alg #-}

runWithServer ::
  forall (serverName :: Symbol) n s ts m a.
  TQueue n (Some n s) ->
  Labelled serverName (RequestC s ts n) m a ->
  m a
runWithServer chan = runReader chan . unRequestC . runLabelled
{-# INLINE runWithServer #-}
