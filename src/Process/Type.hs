{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Process.Type where

import Control.Concurrent (ThreadId)
import Control.Concurrent.STM (TMVar)
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
import Process.TChan

type Sum :: (Type -> Type) -> [Type] -> Type
data Sum f r where
  Sum :: f t -> Sum f r

type Some :: (Type -> Type) -> Type
data Some f where
  Some :: Sum f r -> Some f

class ToSig a b where
  toSig :: a -> b a

inject :: ToSig e f => e -> Some f
inject = Some . Sum . toSig
{-# INLINE inject #-}

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

data RespVal a where
  RespVal :: TMVar a -> RespVal a

newtype NodeId = NodeId Int deriving (Show, Eq, Ord)

type ProcessState :: (Type -> Type) -> [Type] -> Type
data ProcessState s ts = ProcessState
  { pChan :: TChan (Some s),
    pid :: NodeId,
    tid :: ThreadId
  }

data ProcessInfo = ProcessInfo
  { ppid :: NodeId,
    ptid :: ThreadId,
    psize :: Int
  }

state2info :: ProcessState s ts -> IO ProcessInfo
state2info (ProcessState pc pid tid) = do
  ps <- getChanSize pc
  pure (ProcessInfo pid tid ps)

instance Show ProcessInfo where
  show (ProcessInfo pid tid psize) =
    "Prcess info: "
      ++ "Pid "
      ++ show pid
      ++ ", Tid "
      ++ show tid
      ++ ", TChan size "
      ++ show psize

data Result = Result
  { terminateTime :: UTCTime,
    rpid :: NodeId,
    result :: Either SomeException ()
  }

addOne :: NodeId -> NodeId
addOne (NodeId i) = NodeId (i + 1)
{-# INLINE addOne #-}
