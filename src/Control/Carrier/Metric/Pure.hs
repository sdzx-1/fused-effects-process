{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Control.Carrier.Metric.Pure
  ( runMetric,
    showMetric,
  )
where

import Control.Carrier.State.Strict
  ( Algebra,
    StateC (..),
    evalState,
    get,
    modify,
  )
import Control.Effect.Labelled
  ( Algebra (..),
    type (:+:) (..),
  )
import Control.Effect.Metric
  ( K,
    Metric (..),
    NameVector (..),
    Vlength (vlength),
  )
import Data.Data (Proxy (..))
import Data.Default.Class
import Data.IntMap (IntMap)
import Data.IntMap.Strict (adjust)
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (fromJust)
import Data.Vector ((!))
import GHC.TypeLits
  ( KnownNat,
    natVal,
  )
import Prelude hiding (replicate)

toi :: forall s. (KnownNat s) => K s -> Int
toi _ = fromIntegral $ natVal (Proxy :: Proxy s)
{-# INLINE toi #-}

getIndex :: (KnownNat s, Default a) => (a -> K s) -> Int
getIndex v1 = toi . v1 $ def
{-# INLINE getIndex #-}

newtype MetriC v m a = MetriC {unMetric :: StateC (IntMap Int) m a}
  deriving (Functor, Applicative, Monad)

instance
  (Algebra sig m, Default v, NameVector v) =>
  Algebra (Metric v :+: sig) (MetriC v m)
  where
  alg hdl sig ctx = MetriC $ case sig of
    L (Inc g) -> do
      modify (adjust @Int (+ 1) (getIndex g))
      pure ctx
    L (Dec g) -> do
      modify (adjust @Int (\x -> x - 1) (getIndex g))
      pure ctx
    L (GetVal g) -> do
      im <- get @(IntMap Int)
      let v = IntMap.lookup (getIndex g) im
      pure (fromJust v <$ ctx)
    L (PutVal g v) -> do
      modify (IntMap.update (const (Just v)) (getIndex g))
      pure ctx
    L GetAll -> do
      im <- get @(IntMap Int)
      let ls = IntMap.toList im
          v = foldr (\(i, a) b -> (vName @v undefined ! i, a) : b) [] ls
      pure (v <$ ctx)
    L Reset -> do
      modify @(IntMap Int) (IntMap.map (const 0))
      pure ctx
    R signa -> alg (unMetric . hdl) (R signa) ctx
  {-# INLINE alg #-}

runMetric ::
  forall v m a.
  ( Default v,
    Vlength v,
    Functor m
  ) =>
  MetriC v m a ->
  m a
runMetric f = do
  let init = IntMap.fromList $ zip [0 .. vlength @v undefined - 1] (repeat 0)
  evalState init $ unMetric f
{-# INLINE runMetric #-}

showMetric :: [(String, Int)] -> String
showMetric [] = []
showMetric ((name, val) : xs) =
  name ++ ": " ++ show val ++ "\n" ++ showMetric xs
{-# INLINE showMetric #-}
