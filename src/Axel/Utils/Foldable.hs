module Axel.Utils.Foldable where

import Axel.Prelude

-- Adapted from https://github.com/purescript/purescript-foldable-traversable/blob/29d5b873cc86f17e0082d777629819a96bdbc7a1/src/Data/Foldable.purs#L256-L256.
intercalate :: (Foldable f, Monoid m) => m -> f m -> m
intercalate sep xs = snd $ foldl go (True, mempty) xs
  where
    go (isInit, acc) x =
      ( False
      , if isInit
          then x
          else acc <> sep <> x)

mapWithPrev :: (Foldable f) => (Maybe a -> a -> b) -> f a -> [b]
mapWithPrev f =
  snd . foldr (\x (prev, acc) -> (Just x, f prev x : acc)) (Nothing, [])
