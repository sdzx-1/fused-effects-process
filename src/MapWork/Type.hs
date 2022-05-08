{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
-- {-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module MapWork.Type where

-- import Control.Monad
-- import Data.Data
import Data.Kind
import GHC.TypeLits

-- import Text.Printf

type Piple :: Type -> Type -> Nat -> Type
data Piple a b n where
  (:>) :: KnownNat n => (a -> IO b) -> Piple b c n -> Piple a c (n + 1)
  EPoint :: (a -> IO b) -> Piple a b 0

infixr 4 :>

t =
  (\x -> print x >> pure (x :: Int))
    :> (\x -> print x >> pure x)
    :> (\x -> print x >> pure x)
    :> (\x -> print x >> pure x)
    :> (\x -> print x >> pure x)
    :> EPoint (\x -> print x >> pure x)

-- evalPiple :: forall a b n. KnownNat n => a -> Piple a b n -> IO [b]
-- evalPiple a (EPoint fun) = do
--   putStrLn "level 0"
--   fun a
-- evalPiple a (fun :> piple) = do
--   let level = natVal @n Proxy
--   printf "level %d\n" level
--   ls <- fun a
--   forM ls $ \v -> do
--     evalPiple v piple

-- r = evalPiple 0 t

-- gPiple :: forall a n. KnownNat n => ([a], Piple a n) -> IO ()
-- gPiple (as, EPoint fun) = do
--   putStrLn "level 0"
--   forM_ as fun
-- gPiple (as, fun :> piple) = do
--   let level = natVal @n Proxy
--   printf "level %d\n" level
--   bs <- concat <$> mapM fun as
--   gPiple (bs, piple)

-- rr = gPiple ([0], t)
