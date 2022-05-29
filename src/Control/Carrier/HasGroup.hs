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

module Control.Carrier.HasGroup
  ( module G,
    GroupState (..),
    runWithGroup,
  )
where

import Control.Algebra
  ( Algebra (..),
    type (:+:) (..),
  )
import Control.Carrier.State.Strict
  ( StateC (..),
    evalState,
    gets,
  )
import Control.Concurrent.STM
  ( atomically,
    newEmptyTMVarIO,
  )
import Control.Effect.HasGroup as G
import Control.Effect.Labelled
  ( Labelled,
    runLabelled,
  )
import Control.Monad
  ( forM,
  )
import Control.Monad.IO.Class (MonadIO (..))
import Data.Kind (Type)
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.TypeLits (Symbol)
import Process.TChan
  ( TChan (..),
    writeTChan,
  )
import Process.Type
  ( NodeId,
    RespVal (..),
    Some,
    inject,
  )

type GroupState :: (Type -> Type) -> Type
newtype GroupState s = GroupState
  { workMap :: Map NodeId (TChan (Some s))
  }

type RequestC :: (Type -> Type) -> [Type] -> (Type -> Type) -> Type -> Type
newtype RequestC s ts m a = RequestC {unRequestC :: StateC (GroupState s) m a}
  deriving (Functor, Applicative, Monad, MonadIO)

instance (Algebra sig m, MonadIO m) => Algebra (Request s ts :+: sig) (RequestC s ts m) where
  alg hdl sig ctx = RequestC $ case sig of
    L (SendReq i t) -> do
      wm <- gets @(GroupState s) workMap
      case Map.lookup i wm of
        Nothing -> do
          liftIO $ print $ "not found pid: " ++ show i
          pure ctx
        Just ch -> do
          liftIO $ atomically $ Process.TChan.writeTChan ch (inject t)
          pure ctx
    L (SendAllCall t) -> do
      wm <- gets @(GroupState s) workMap
      mvs <- forM (Map.toList wm) $ \(idx, ch) -> do
        mv <- liftIO newEmptyTMVarIO
        liftIO $ atomically $ Process.TChan.writeTChan ch (inject (t $ RespVal mv))
        pure (idx, mv)
      pure (mvs <$ ctx)
    L (SendAllCast t) -> do
      wm <- gets @(GroupState s) workMap
      Map.traverseWithKey
        (\_ ch -> liftIO $ atomically $ Process.TChan.writeTChan ch (inject t))
        wm
      pure ctx
    R signa -> alg (unRequestC . hdl) (R signa) ctx
  {-# INLINE alg #-}

runWithGroup ::
  forall serverName s ts m a.
  MonadIO m =>
  GroupState s ->
  Labelled (serverName :: Symbol) (RequestC s ts) m a ->
  m a
runWithGroup ws f = do
  evalState @(GroupState s) ws $
    unRequestC $
      runLabelled f
{-# INLINE runWithGroup #-}
