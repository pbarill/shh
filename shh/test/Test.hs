{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ExtendedDefaultRules #-}
module Main where

import Shh
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck
import Control.Exception
import Control.Monad
import Data.Char
import Data.Word
import Control.Concurrent.Async
import System.IO

$(load SearchPath ["tr", "echo", "cat", "true", "false", "mktemp", "sleep", "rm", "printf"])

main = do
    putStrLn "################################################"
    putStrLn " These tests require that certain binaries"
    putStrLn " exist on your $PATH. If you are getting"
    putStrLn " failures, please check that it's not because"
    putStrLn " they are missing."
    putStrLn "################################################"
    defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [unitTests, properties]

bytesToString :: [Word8] -> String
bytesToString = map (chr . fromIntegral)

properties :: TestTree
properties = testGroup "Properties"
    [ testProperty "trim = trim . trim" $ \l -> trim l == trim (trim l)
    , testProperty "encodeIdentifier = encodeIdentifier . encodeIdentifier"
        $ \l -> encodeIdentifier l == encodeIdentifier (encodeIdentifier l)
    , testProperty "pureProc id" $ \s -> ioProperty $ do
        let
            s' = bytesToString s
        k <- readProc $ s' >>> pureProc id
        pure $ s' === k
    , testProperty "pureProc (map toUpper)" $ \(ASCIIString s) -> ioProperty $ do
        k <- readProc $ s >>> pureProc (map toUpper)
        pure $ map toUpper s === k
    ]

withTmp :: (FilePath -> IO a) -> IO a
withTmp = bracket (readTrim mktemp) rm

unitTests :: TestTree
unitTests = testGroup "Unit tests"
    [ testCase "Read stdout" $ do
        l <- readProc $ echo "test"
        l @?= "test\n"
    , testCase "Redirect to /dev/null" $ do
        l <- readProc $ echo "test" &> devNull
        l @?= ""
    , testCase "Redirect to file (Truncate)" $ withTmp $ \t -> do
        echo "test" &> Truncate t
        r <- readProc $ cat t
        "test\n" @?= r
    , testCase "Redirect to file (Append)" $ withTmp $ \t -> do
        echo "test" &> Truncate t
        echo "test" &> Append t
        r <- readProc $ cat t
        "test\ntest\n" @?= r
    , testCase "Long pipe" $ do
        r <- readProc $ echo "test" |> tr "-d" "e" |> tr "-d" "s"
        r @?= "tt\n"
    , testCase "Pipe stderr" $ do
        r <- readProc $ echo "test" &> StdErr |!> cat
        r @?= "test\n"
    , testCase "Lazy read" $ do
        withRead (cat "/dev/urandom" |> tr "-C" "-d" "a") $ \s -> do
            take 6 s @?= "aaaaaa"
    , testCase "Multiple outputs" $ do
        l <- readProc $ (echo (1 :: Int) >> echo (2 :: Int)) |> cat
        l @?= "1\n2\n"
    , testCase "Terminate upstream processes" $ do
        Left x <- catchFailure (mkProc "false" ["dummy"] |> (sleep 1 >> false "Didn't kill"))
        x @?= Shh.Failure "false" ["dummy"] 1
    , testCase "Write to process" $ withTmp $ \t -> do
        writeProc (cat &> Truncate t) "Hello"
        r <- readProc (cat t)
        r @?= "Hello"
        writeProc (cat &> Truncate t) "Goodbye"
        r <- readProc (cat t)
        r @?= "Goodbye"
    , testCase "apply" $ do
        r <- apply (tr "-d" "es") "test"
        r @?= "tt"
    , testCase "ignoreFailure" $ replicateM_ 30 $ do
        r <- readProc $ ignoreFailure false |> echo "Hello"
        r @?= "Hello\n"
    , testCase "Read failure" $ replicateM_ 30 $ do
        Left r <- catchFailure $ readProc $ false "dummy"
        r @?= Shh.Failure "false" ["dummy"] 1
    , testCase "Read failure chain start" $ replicateM_ 30 $ do
        Left r <- catchFailure $ readProc $ false "dummy" |> echo "test" |> true
        r @?= Shh.Failure "false" ["dummy"] 1
    , testCase "Read failure chain middle" $ replicateM_ 30 $ do
        Left r <- catchFailure $ readProc $ echo "test" |> false "dummy" |> true
        r @?= Shh.Failure "false" ["dummy"] 1
    , testCase "Read failure chain end" $ replicateM_ 30 $ do
        Left r <- catchFailure $ readProc $ echo "test" |> true |> false "dummy"
        r @?= Shh.Failure "false" ["dummy"] 1
    , testCase "Lazy read checks code" $ replicateM_ 30 $ do
        Left r <- catchFailure $ withRead (cat "/dev/urandom" |> false "dummy") $ pure . take 3
        r @?= Shh.Failure "false" ["dummy"] 1
    , testCase "Identifier odd chars" $ encodeIdentifier "1@3.-" @?= "_1_3__"
    , testCase "Identifier make lower" $ encodeIdentifier "T.est" @?= "t_est"
    , testCase "pureProc closes input" $ do
        r <- readProc $ cat "/dev/urandom" |> pureProc (const "test")
        r @?= "test"
    , testCase "pureProc closes output" $ do
        r <- readProc $ pureProc (const "test") |> cat
        r @?= "test"
    , testCase "pureProc doesn't close std handles" $ do
        runProc $ pureProc (const "")
        b <- hIsOpen stdin
        b @?= True
        b <- hIsOpen stdout
        b @?= True
        runProc $ pureProc (const "") &> StdErr
        b <- hIsOpen stderr
        b @?= True
    , testCase "pureProc sanity check" $ do
        r <- readProc $ printf "Hello" |> pureProc id |> cat
        r @?= "Hello"
    ]
