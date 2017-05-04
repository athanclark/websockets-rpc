{-# LANGUAGE
    RankNTypes
  , ScopedTypeVariables
  , NamedFieldPuns
  #-}

module Network.WebSockets.RPC.ACKable
  ( ackableRPCServer
  , ackableRPCClient
  , ACKable (..)
  ) where

import Network.WebSockets.RPC
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Hashable (Hashable)
import Control.Applicative ((<|>))
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (newTVarIO, readTVarIO, writeTVar, modifyTVar, TVar)


data ACKable owner a = ACKable
  { ackableID    :: UUID
  , ackableOwner :: owner
  , ackableData  :: Maybe a -- ^ 'Data.Maybe.Nothing' represents an ACK
  }


ack :: UUID -> owner -> ACKable owner a
ack ackableID ackableOwner = ACKable
  { ackableID
  , ackableOwner
  , ackableData = Nothing
  }




ackableRPCServer :: forall sub sup rep com m owner
                  . ( MonadIO m
                    , Eq owner
                    , Hashable owner
                    )
                 => (forall a. m a -> IO a)
                 -> owner
                 -> RPCServer sub sup rep com m
                 -> RPCServer (ACKable owner sub) (ACKable owner sup) (ACKable owner rep) com m
ackableRPCServer runM serverOwner rpc RPCServerParams{reply,complete} eSubSup = do
  replyMailbox <- liftIO $ newTVarIO HM.empty
  ownerPending <- liftIO $ newTVarIO (HM.empty :: HM.HashMap owner (HS.HashSet UUID))

  let params :: owner -> RPCServerParams rep com m
      params clientOwner = RPCServerParams
        { reply = \r -> do
            ackableID <- liftIO nextRandom
            let op =
                  reply ACKable
                    { ackableID
                    , ackableOwner = serverOwner
                    , ackableData = Just r
                    }
            liftIO $ do
              expBackoff <- mkBackoff (runM op) $ do
                replies <- readTVarIO replyMailbox
                atomically $ do
                  modifyTVar replyMailbox $ HM.delete ackableID
                  modifyTVar ownerPending $ HM.delete clientOwner
                case HM.lookup ackableID replies of
                  Nothing -> pure ()
                  Just (_,expBackoff) -> Async.cancel expBackoff
              atomically $ do
                modifyTVar replyMailbox $ HM.insert ackableID (r, expBackoff)
                modifyTVar ownerPending $ HM.insertWith HS.union clientOwner (HS.singleton ackableID)
            op
        , complete
        }

  case eSubSup of
    Left ACKable{ackableID,ackableOwner,ackableData} ->
      case ackableData of
        Nothing ->
          liftIO $ putStrLn "Somehow received an ACK from a Sub on a server"
        Just sub -> do
          reply (ack ackableID serverOwner)
          rpc (params ackableOwner) (Left sub)
    Right ACKable{ackableID,ackableOwner,ackableData} ->
      case ackableData of
        Nothing -> do
          replies <- liftIO $ readTVarIO replyMailbox
          owners <- liftIO $ readTVarIO ownerPending
          case HM.lookup ackableID replies of
            Nothing -> liftIO $ putStrLn $ "Somehow received an ACK that doesn't exist: " ++ show ackableID
            Just (_,expBackoff) -> liftIO $ do
              Async.cancel expBackoff
              atomically $ do
                writeTVar replyMailbox $ HM.delete ackableID replies
                writeTVar ownerPending $ HM.adjust (HS.delete ackableID) ackableOwner owners

        Just sup -> do
          reply (ack ackableID serverOwner)
          rpc (params ackableOwner) (Right sup)



ackableRPCClient :: forall sub sup rep com m owner
                  . ( MonadIO m
                    , Eq owner
                    , Hashable owner
                    )
                 => (forall a. m a -> IO a)
                 -> owner
                 -> RPCClient sub sup rep com m
                 -> m (RPCClient (ACKable owner sub) (ACKable owner sup) (ACKable owner rep) com m)
ackableRPCClient runM clientOwner RPCClient{subscription,onSubscribe,onReply,onComplete} = do
  subscriptionMailbox <- liftIO $ newTVarIO HM.empty
  supplyMailbox <- liftIO $ newTVarIO HM.empty
  ownerPending <- liftIO $ newTVarIO (HM.empty :: HM.HashMap owner (HS.HashSet UUID))


  ackableID <- liftIO nextRandom
  let ackParams :: Maybe owner -> RPCClientParams (ACKable owner sup) m -> RPCClientParams sup m
      ackParams mOwner RPCClientParams{supply,cancel} = RPCClientParams
        { supply = \s -> do
            ackableID <- liftIO nextRandom
            let op =
                  supply ACKable
                    { ackableID
                    , ackableOwner = clientOwner
                    , ackableData = Just s
                    }
            liftIO $ do
              expBackoff <- mkBackoff (runM op) $ do
                subscriptions <- readTVarIO subscriptionMailbox
                supplies <- readTVarIO supplyMailbox
                atomically $ do
                  modifyTVar subscriptionMailbox $ HM.delete ackableID
                  modifyTVar supplyMailbox $ HM.delete ackableID
                  case mOwner of
                    Nothing -> pure ()
                    Just serverOwner -> modifyTVar ownerPending $ HM.delete serverOwner
                case Left <$> HM.lookup ackableID subscriptions <|> Right <$> HM.lookup ackableID supplies of
                  Nothing -> pure ()
                  Just (Left (_,expBackoff)) -> Async.cancel expBackoff
                  Just (Right (_,expBackoff)) -> Async.cancel expBackoff
              atomically $ do
                modifyTVar supplyMailbox $ HM.insert ackableID (s,expBackoff)
                case mOwner of
                  Nothing -> pure ()
                  Just serverOwner -> modifyTVar ownerPending $ HM.insertWith HS.union serverOwner (HS.singleton ackableID)
            op
        , cancel
        }
  pure RPCClient
    { subscription = ACKable
        { ackableID
        , ackableOwner = clientOwner
        , ackableData = Just subscription
        }
    , onSubscribe = onSubscribe . ackParams Nothing
    , onReply = \params ACKable{ackableID,ackableData,ackableOwner} -> case ackableData of
        Nothing -> do
          subscriptions <- liftIO $ readTVarIO subscriptionMailbox
          supplies <- liftIO $ readTVarIO supplyMailbox
          owners <- liftIO $ readTVarIO ownerPending
          case Left <$> HM.lookup ackableID subscriptions <|> Right <$> HM.lookup ackableID supplies of
            Nothing -> pure ()
            Just (Left (_,expBackoff)) -> liftIO $ do
              atomically $ do
                writeTVar subscriptionMailbox $ HM.delete ackableID subscriptions
                writeTVar ownerPending $ HM.adjust (HS.delete ackableID) ackableOwner owners
              Async.cancel expBackoff
            Just (Right (_,expBackoff)) -> liftIO $ do
              atomically $ do
                writeTVar supplyMailbox $ HM.delete ackableID supplies
                writeTVar ownerPending $ HM.adjust (HS.delete ackableID) ackableOwner owners
              Async.cancel expBackoff
        Just rep -> do
          (supply params) (ack ackableID clientOwner)
          onReply (ackParams (Just ackableOwner) params) rep
    , onComplete
    }




second = 1000000
minute = 60 * second
hour = 60 * minute
day = 24 * hour
week = 7 * day

mkBackoff op x = do
  spentWaiting <- newIORef (0 :: Int)
  async $ do
    toWait <- readIORef spentWaiting
    writeIORef spentWaiting (toWait + 1)
    let toWait' = 2 ^ toWait
        soFar = sum $ (\x -> (2 ^ x) * second) <$> [0..toWait]

    when (soFar > week) x

    threadDelay $ second * (toWait' + 10)
    op
