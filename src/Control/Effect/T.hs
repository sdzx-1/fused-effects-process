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

module Control.Effect.T where

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
      ( TMVar,
        TQueue,
        atomically,
        newEmptyTMVarIO,
        newTQueueIO,
        putTMVar,
        readTQueue,
        takeTMVar,
        writeTQueue
      ),
    STM,
  )
import Control.Monad.Class.MonadTime (DiffTime)
import Control.Monad.Class.MonadTimer
  ( MonadTimer (timeout),
  )
import Control.Monad.IOSim
  ( IOSim,
  )
import Data.Kind
  ( Type,
  )
import GHC.TypeLits
  ( Symbol,
  )
import Process.Type (Elem, Elems)

type Some :: (Type -> Type) -> ((Type -> Type) -> Type -> Type) -> Type
data Some n f where
  Some :: !(f n (t n)) -> Some n f

inject ::
  forall
    (e :: (Type -> Type) -> Type)
    (f :: ((Type -> Type) -> Type -> Type))
    (n :: Type -> Type).
  ToSig e f n =>
  e n ->
  Some n f
inject = Some . toSig
{-# INLINE inject #-}

class
  ToSig
    (e :: (Type -> Type) -> Type)
    (f :: (Type -> Type) -> Type -> Type)
    (n :: Type -> Type)
  where
  toSig :: e n -> f n (e n)

type family ToList (a :: (Type -> Type)) :: [Type]

data RespVal n a where
  RespVal :: !(TMVar n a) -> RespVal n a

type family
  TMAP
    (ts :: [(Type -> Type) -> Type])
    (n :: Type -> Type)
  where
  TMAP (l ': ls) n = l n ': TMAP ls n
  TMAP '[] _ = '[]

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
  deriving (Functor, Applicative, Monad)

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

type HasServer (serverName :: Symbol) s ts n sig m =
  ( Elems serverName (TMAP ts n) (ToList (s n)),
    HasLabelled serverName (Request s (TMAP ts n) n) sig m
  )

runWithServer ::
  forall (serverName :: Symbol) n s ts m a.
  TQueue n (Some n s) ->
  Labelled serverName (RequestC s ts n) m a ->
  m a
runWithServer chan = runReader chan . unRequestC . runLabelled
{-# INLINE runWithServer #-}

instance Algebra (Lift (IOSim s)) (IOSim s) where
  alg hdl (LiftWith with) = with hdl

withMessageChan ::
  forall symbol n s sig m.
  ( MonadSTM n,
    Has (Lift n) sig m,
    HasMessageChan symbol s n sig m
  ) =>
  (forall s0. s n s0 %1 -> m ()) ->
  m ()
withMessageChan f = do
  Some v <- blockGetMessage @symbol
  f v
{-# INLINE withMessageChan #-}

withResp ::
  forall n sig m a.
  ( MonadSTM n,
    Has (Lift n) sig m
  ) =>
  RespVal n a %1 ->
  m a ->
  m ()
withResp (RespVal tmv) ma = do
  val <- ma
  sendM @n $ atomically $ putTMVar tmv val
{-# INLINE withResp #-}

forever :: (Applicative f) => f () -> f b
forever a = let a' = a *> a' in a'
{-# INLINE forever #-}

newMessageChan :: forall n s. MonadSTM n => n (TQueue n (Some n s))
newMessageChan = newTQueueIO

type HasMessageChan (symbol :: Symbol) s n sig m =
  (HasLabelled symbol (MessageChan s n) sig m)

type MessageChan ::
  ((Type -> Type) -> Type -> Type) ->
  (Type -> Type) ->
  (Type -> Type) ->
  Type ->
  Type
data MessageChan s n m a where
  GetChan :: MessageChan s n m (TQueue n (Some n s))
  GetSTM :: MessageChan s n m (STM n (Some n s))
  BlockGetMessage :: MessageChan s n m (Some n s)

getChan ::
  forall (symbol :: Symbol) n s sig m.
  HasLabelled symbol (MessageChan s n) sig m =>
  m (TQueue n (Some n s))
getChan = sendLabelled @symbol GetChan
{-# INLINE getChan #-}

getSTM ::
  forall (symbol :: Symbol) n s sig m.
  HasLabelled symbol (MessageChan s n) sig m =>
  m (STM n (Some n s))
getSTM = sendLabelled @symbol GetSTM
{-# INLINE getSTM #-}

blockGetMessage ::
  forall (symbol :: Symbol) n s sig m.
  HasLabelled symbol (MessageChan s n) sig m =>
  m (Some n s)
blockGetMessage = sendLabelled @symbol BlockGetMessage
{-# INLINE blockGetMessage #-}

newtype MessageChanC s n m a = MessageChanC
  { unHasMessageChanC :: ReaderC (TQueue n (Some n s)) m a
  }
  deriving (Functor, Applicative, Monad)

instance
  ( MonadSTM n,
    Has (Lift n) sig m
  ) =>
  Algebra
    (MessageChan s n :+: sig)
    (MessageChanC s n m)
  where
  alg hdl sig ctx = MessageChanC $
    ReaderC $ \c -> case sig of
      L GetChan -> pure (c <$ ctx)
      L GetSTM -> pure (readTQueue c <$ ctx)
      L BlockGetMessage -> do
        val <- sendM @n $ atomically $ readTQueue c
        pure (val <$ ctx)
      R signa -> alg (runReader c . unHasMessageChanC . hdl) signa ctx
  {-# INLINE alg #-}

runServer ::
  forall (symbol :: Symbol) n s m a.
  TQueue n (Some n s) ->
  Labelled symbol (MessageChanC s n) m a ->
  m a
runServer chan = runReader chan . unHasMessageChanC . runLabelled
{-# INLINE runServer #-}
