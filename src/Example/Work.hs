{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Example.Work where

import Control.Algebra (Has, type (:+:))
import Control.Carrier.Error.Either (Error, throwError)
import Control.Carrier.Reader (Reader, asks)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO (..))
import Example.Type
import Control.Carrier.HasServer (HasServer)
import Process.Util
  ( MessageChan,
    withMessageChan,
    withResp,
  )

-------------------------------------Manager - Work, Work
mWork ::
  ( MonadIO m,
    Has (MessageChan SigCommand) sig m,
    HasServer "log" SigLog '[Log] sig m,
    Has (Reader WorkInfo :+: Error TerminateProcess) sig m
  ) =>
  m ()
mWork = forever $
  withMessageChan @SigCommand $ \case
    SigCommand1 Stop -> do
      -- pid <- asks workPid
      -- cast @"log" $ LW $ "terminate process: " ++ show pid
      throwError TerminateProcess
    SigCommand2 (Info rsp) ->
      withResp
        rsp
        $ do
          pid <- asks workPid
          pure (pid, "running")
    SigCommand3 (ProcessStartTimeoutCheck rsp) ->
      withResp
        rsp
        $ do
          -- pid <- asks workPid
          -- cast @"log" $
          --   LW $
          --     "process "
          --       ++ show pid
          --       ++ " response timoue check"
          pure TimeoutCheckFinish
    SigCommand4 (ProcessWork work rsp) -> do
      withResp
        rsp
        $ do
          liftIO work
