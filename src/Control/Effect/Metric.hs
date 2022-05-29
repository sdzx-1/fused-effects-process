{-# LANGUAGE AllowAmbiguousTypes #-}
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

module Control.Effect.Metric
  ( Metric(..),
    inc,
    dec,
    getVal,
    putVal,
    getAll,
    K (..),
    Vlength (..),
    NameVector (..),
    module Data.Default.Class,
  )
where

import Control.Carrier.Reader
  ( Has,
  )
import Control.Effect.Labelled
  ( send,
  )
import Data.Default.Class (Default (..))
import Data.Kind (Type)
import qualified Data.Vector as V
import GHC.TypeLits
  ( KnownNat,
    Nat,
  )
import Prelude hiding (replicate)

type K :: Nat -> Type
data K s where
  K :: K s

class Vlength a where
  vlength :: a -> Int

class NameVector a where
  vName :: a -> V.Vector String

type Metric :: Type -> (Type -> Type) -> Type -> Type
data Metric v m a where
  Inc :: KnownNat s => (v -> K s) -> Metric v m ()
  Dec :: KnownNat s => (v -> K s) -> Metric v m ()
  GetVal :: KnownNat s => (v -> K s) -> Metric v m Int
  PutVal :: KnownNat s => (v -> K s) -> Int -> Metric v m ()
  GetAll :: Metric v m [(String, Int)]

inc :: (Has (Metric v) sig m, KnownNat s) => (v -> K s) -> m ()
inc g = send (Inc g)
{-# INLINE inc #-}

dec :: (Has (Metric v) sig m, KnownNat s) => (v -> K s) -> m ()
dec g = send (Dec g)
{-# INLINE dec #-}

getVal :: (Has (Metric v) sig m, KnownNat s) => (v -> K s) -> m Int
getVal g = send (GetVal g)
{-# INLINE getVal #-}

putVal :: (Has (Metric v) sig m, KnownNat s) => (v -> K s) -> Int -> m ()
putVal g v = send (PutVal g v)
{-# INLINE putVal #-}

getAll :: forall v sig m. Has (Metric v) sig m => m [(String, Int)]
getAll = send (GetAll @v)
{-# INLINE getAll #-}
