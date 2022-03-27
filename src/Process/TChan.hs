module Process.TChan
  ( TChan (..),
    writeTChan,
    readTChan,
    newTChanIO,
    getChanSize,
  )
where

import qualified Control.Concurrent.STM as T
import qualified Control.Concurrent.STM.TChan as T
import qualified Control.Concurrent.STM.TVar as T
import Data.IORef

data TChan a = TChan (T.TVar Int) (T.TChan a)

writeTChan :: TChan a -> a -> T.STM ()
writeTChan (TChan tv tc) a = do
  T.writeTChan tc a
  T.modifyTVar tv (+ 1)

newTChanIO :: IO (TChan a)
newTChanIO = T.atomically $ TChan <$> T.newTVar 0 <*> T.newTChan

readTChan :: TChan a -> T.STM a
readTChan (TChan tv tc) = do
  T.modifyTVar' tv (\x -> x - 1)
  T.readTChan tc

getChanSize :: TChan a -> IO Int
getChanSize (TChan tv _) = T.atomically $ T.readTVar tv
