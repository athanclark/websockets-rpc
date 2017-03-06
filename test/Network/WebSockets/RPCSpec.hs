{-# LANGUAGE
    ScopedTypeVariables
  #-}

module Network.WebSockets.RPCSpec (spec) where

import Network.WebSockets.RPC
import Network.WebSockets.RPC.Types (RPCIdentified, Subscribe, Supply, Reply, Complete, ClientToServer, ServerToClient)
import Data.Aeson (encode, decode, FromJSON, ToJSON)

import Test.Tasty
import Test.Tasty.QuickCheck as QC
import Test.QuickCheck
import Test.QuickCheck.Instances


spec :: TestTree
spec = testGroup "Network.WebSockets.RPC"
  [ QC.testProperty "RPCIdentified parse/print iso"
      (\(x :: RPCIdentified ()) -> invariantJSON x)
  , QC.testProperty "Subscribe parse/print iso"
      (\(x :: Subscribe ()) -> invariantJSON x)
  , QC.testProperty "Supply parse/print iso"
      (\(x :: Supply ()) -> invariantJSON x)
  , QC.testProperty "Reply parse/print iso"
      (\(x :: Reply ()) -> invariantJSON x)
  , QC.testProperty "Complete parse/print iso"
      (\(x :: Complete ()) -> invariantJSON x)
  , QC.testProperty "ClientToServer parse/print iso"
      (\(x :: ClientToServer () ()) -> invariantJSON x)
  , QC.testProperty "ServerToClient parse/print iso"
      (\(x :: ServerToClient () ()) -> invariantJSON x)
  ]


invariantJSON :: (FromJSON a, ToJSON a, Eq a, Show a) => a -> Property
invariantJSON x = decode (encode x) === Just x
