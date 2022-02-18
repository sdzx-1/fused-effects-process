{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.Type where

import Control.Concurrent (MVar, ThreadId)
import Control.Concurrent.STM
import Control.Exception (SomeException)
import Data.Kind
  ( Constraint,
    Type,
  )
import Data.Time
import GHC.TypeLits
  ( ErrorMessage
      ( ShowType,
        Text,
        (:<>:)
      ),
    Symbol,
    TypeError,
  )

type Sum :: (Type -> Type) -> [Type] -> Type
data Sum f r where
  Sum :: f t -> Sum f r

type Some :: (Type -> Type) -> Type
data Some f where
  Some :: f a -> Some f

class ToSig a b where
  toSig :: a -> b a

inject :: ToSig e f => e -> Sum f r
inject = Sum . toSig

type family ToList (a :: (Type -> Type)) :: [Type]

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

-- call response
data RespVal a where
  RespVal :: MVar a -> RespVal a

-- process fork
data Fork = Fork

-- workGroup, Process State (Process -- Worker)
data ProcessState s ts = ProcessState
  { pChan :: TChan (Sum s ts),
    pid :: Int,
    tid :: ThreadId
  }

data Result = Result
  { terminateTime :: UTCTime,
    rpid :: Int,
    result :: Either SomeException ()
  }
