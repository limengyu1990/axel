{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE UndecidableInstances #-}

module Axel.Monad.Haskell.GHC where

import Axel.Error (Error(MacroError))
import Axel.Monad.Haskell.Stack (axelStackageId, stackageResolverWithAxel)

import Control.Monad.Except (MonadError(throwError))
import Control.Monad.IO.Class (MonadIO, liftIO)

import System.Exit (ExitCode(ExitFailure, ExitSuccess))
import System.Process (readProcessWithExitCode)

class (MonadError Error m) =>
      MonadGHC m
  where
  ghcCompile :: FilePath -> m String
  ghcInterpret :: FilePath -> m String

-- NOTE This is undecidable, but `mtl` uses undecidable instances in this scenario(?)....
--      Plus, I can't actually come up with a better solution.
instance (MonadError Error m, MonadIO m) => MonadGHC m where
  ghcCompile :: FilePath -> m String
  ghcCompile filePath = do
    (exitCode, stdout, stderr) <-
      liftIO $
      readProcessWithExitCode
        "stack"
        [ "--resolver"
        , stackageResolverWithAxel
        , "ghc"
        , "--"
        , "-v0"
        , "-ddump-json"
        , filePath
        ]
        ""
    case exitCode of
      ExitSuccess -> pure stdout
      ExitFailure _ -> throwError $ MacroError stderr
  ghcInterpret :: FilePath -> m String
  ghcInterpret filePath = do
    (exitCode, stdout, stderr) <-
      liftIO $
      readProcessWithExitCode
        "stack"
        [ "--resolver"
        , stackageResolverWithAxel
        , "runghc"
        , "--package"
        , axelStackageId
        , "--"
        , filePath
        ]
        ""
    case exitCode of
      ExitSuccess -> pure stdout
      ExitFailure _ -> throwError $ MacroError stderr
