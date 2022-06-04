{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.Effect.Type
  ( Some (..),
    inject,
    ToSig (..),
    ToList,
    RespVal (..),
    TMAP,
    Elem,
    Elems,
  )
where

import Control.Algebra (Algebra (..))
import Control.Carrier.Lift (Lift (..))
import Control.Monad.Class.MonadSTM.Strict (StrictTMVar)
import Control.Monad.IOSim
  ( IOSim,
  )
import Data.Kind
  ( Type,
  )
import GHC.Base (Constraint)
import GHC.TypeLits
  ( ErrorMessage (ShowType, Text, (:<>:)),
    Symbol,
    TypeError,
  )

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
  RespVal :: StrictTMVar n a -> RespVal n a

type family
  TMAP
    (ts :: [(Type -> Type) -> Type])
    (n :: Type -> Type)
  where
  TMAP (l ': ls) n = l n ': TMAP ls n
  TMAP '[] _ = '[]

instance Algebra (Lift (IOSim s)) (IOSim s) where
  alg hdl (LiftWith with) = with hdl
  {-# INLINE alg #-}

type family Elem (name :: Symbol) (t :: Type) (ts :: [Type]) :: Constraint where
  Elem name t '[] =
    TypeError
      ( 'Text "server "
          :<>: 'ShowType name
          ':<>: 'Text " not add "
          :<>: 'ShowType t
          :<>: 'Text " to it method list"
      )
  Elem name t (t ': xs) = ()
  Elem name t (t1 ': xs) = Elem name t xs

type family ElemO (name :: Symbol) (t :: Type) (ts :: [Type]) :: Constraint where
  ElemO name t '[] =
    TypeError
      ( 'Text "server "
          :<>: 'ShowType name
          ':<>: 'Text " not support method "
          :<>: 'ShowType t
      )
  ElemO name t (t ': xs) = ()
  ElemO name t (t1 ': xs) = ElemO name t xs

type family Elems (name :: Symbol) (ls :: [Type]) (ts :: [Type]) :: Constraint where
  Elems name (l ': ls) ts = (ElemO name l ts, Elems name ls ts)
  Elems name '[] ts = ()
