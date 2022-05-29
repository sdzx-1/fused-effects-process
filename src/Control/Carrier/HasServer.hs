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

module Control.Carrier.HasServer
  ( module S,
    runWithServer,
  )
where

import Control.Carrier.Error.Either
  ( Algebra,
  )
import Control.Carrier.Reader
  ( ReaderC (..),
    runReader,
  )
import Control.Concurrent.STM (atomically)
import Control.Effect.HasServer as S
import Control.Effect.Labelled
  ( Algebra (..),
    Labelled,
    runLabelled,
    type (:+:) (..),
  )
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind
  ( Type,
  )
import GHC.TypeLits
  ( Symbol,
  )
import Process.TChan
import Process.Type
  ( Some (..),
    inject,
  )

type RequestC :: (Type -> Type) -> [Type] -> (Type -> Type) -> Type -> Type
newtype RequestC s ts m a = RequestC {unRequestC :: ReaderC (TChan (Some s)) m a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m) => Algebra (Request s ts :+: sig) (RequestC s ts m) where
  alg hdl sig ctx = RequestC $
    ReaderC $ \c -> case sig of
      L (SendReq t) -> do
        liftIO $ atomically $ writeTChan c (inject t)
        pure ctx
      R signa -> alg (runReader c . unRequestC . hdl) signa ctx
  {-# INLINE alg #-}

-- client
runWithServer ::
  forall serverName s ts m a.
  TChan (Some s) ->
  Labelled (serverName :: Symbol) (RequestC s ts) m a ->
  m a
runWithServer chan f =
  runReader chan $ unRequestC $ runLabelled f
{-# INLINE runWithServer #-}
