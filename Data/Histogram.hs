{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
module Data.Histogram ( Histogram(..)
                      , histBin
                      , underflows
                      , overflows
                      , outOfRange
                      , asList
                      , module Data.Histogram.Bin
                      ) where

import Data.Array.Vector
import Data.Histogram.Bin

-- | Immutable histogram
data Histogram bin a where
    Histogram :: (Bin bin, UA a, Num a) => 
                 bin
              -> (a,a)
              -> UArr a
              -> Histogram bin a

instance (Show a, Show (BinValue bin)) => Show (Histogram bin a) where
    show h@(Histogram bin (u,o) a) = unlines $ map showT $ asList h
        where
          showT (x,y) = show x ++ "\t" ++ show y

-- | Histogram bins
histBin :: Histogram bin a -> bin
histBin (Histogram bin _ _) = bin

-- | Number of underflows
underflows :: Histogram bin a -> a
underflows (Histogram _ (u,_) _) = u

-- | Number of overflows
overflows :: Histogram bin a -> a
overflows (Histogram _ (u,_) _) = u

-- | Under and overflows
outOfRange :: Histogram bin a -> (a,a)
outOfRange (Histogram _ r _) = r

-- | Convert histogram to list
asList :: Histogram bin a -> [(BinValue bin, a)]
asList (Histogram bin _ arr) = map (fromIndex bin) [0..] `zip` fromU arr
