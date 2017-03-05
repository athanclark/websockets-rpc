module Network.WebSockets.RPCSpec (spec) where

import Network.WebSockets.RPC

import Test.Tasty
import Test.Tasty.QuickCheck as QC
import Test.QuickCheck
import Test.QuickCheck.Instances


spec :: TestTree
spec = testGroup "Network.WebSockets.RPC"
  [ QC.testProperty "`someFunction` should pass"
      someFunction
  ]

someFunction :: Bool -> Property
someFunction x = not (not $ x) === x
