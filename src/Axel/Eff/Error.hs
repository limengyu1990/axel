{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeOperators #-}

module Axel.Eff.Error where

import Axel.Parse.AST (Expression, toAxel)

import Control.Monad ((>=>))
import Control.Monad.Freer (type (~>), Eff)
import Control.Monad.Freer.Error (runError)
import qualified Control.Monad.Freer.Error as Effs (Error)

import Data.Semigroup ((<>))

data Error where
  ConvertError :: FilePath -> String -> Error
  MacroError :: FilePath -> Expression ann -> String -> Error
  NormalizeError :: FilePath -> String -> [Expression ann] -> Error
  ParseError :: FilePath -> String -> Error
  ProjectError :: String -> Error

mkFileErrorMsg :: FilePath -> String -> String
mkFileErrorMsg filePath err = "While compiling '" <> filePath <> "':\n\n" <> err

instance Show Error where
  show :: Error -> String
  show (ConvertError filePath err) = mkFileErrorMsg filePath err
  show (MacroError filePath ctxt err) =
    mkFileErrorMsg filePath $
    "While expanding " <> toAxel ctxt <> ":\n\n" <> err
  show (NormalizeError filePath err context) =
    mkFileErrorMsg filePath $
    err <> "\n\n" <> "Context:\n" <> unlines (map toAxel context)
  show (ParseError filePath err) = mkFileErrorMsg filePath err
  show (ProjectError err) = err

fatal :: String -> String -> a
fatal context message = error $ "[FATAL] " <> context <> " - " <> message

unsafeRunError :: (Show e) => Eff (Effs.Error e ': effs) ~> Eff effs
unsafeRunError = runError >=> either (errorWithoutStackTrace . show) pure -- TODO Don't(?) use `error(WithoutStackTrace)` directly