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

module Process.Effect.HasMessageChan
  ( HasMessageChan,
    getChan,
    getSTM,
    blockGetMessage,
    runServer,
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
        readTQueue
      ),
    STM,
  )
import Control.Monad.IO.Class (MonadIO)
import Data.Kind
  ( Type,
  )
import GHC.TypeLits
  ( Symbol,
  )
import Process.Effect.Type (Some (..))

type HasMessageChan (symbol :: Symbol) s n sig m =
  ( Has (Lift n) sig m,
    HasLabelled symbol (MessageChan s n) sig m
  )

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
  deriving (Functor, Applicative, Monad, MonadIO)

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
