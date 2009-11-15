{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- |
-- Module     : Data.Histogram
-- Copyright  : Copyright (c) 2009, Alexey Khudyakov <alexey.skladnoy@gmail.com>
-- License    : BSD3
-- Maintainer : Alexey Khudyakov <alexey.skladnoy@gmail.com>
-- Stability  : experimental
-- 
-- Immutable histograms. 

module Data.Histogram ( -- * Immutable histogram
                        Histogram(..)
                      , module Data.Histogram.Bin
                      -- ** Accessors
                      , histBin
                      , histData
                      , underflows
                      , overflows
                      , outOfRange
                      -- ** Modify histogram
                      , mapHist
                      , mapHistBin
                      , mapHistData
                      -- * Reading histogram
                      , readHistogram
                      , readFileHistogram
                      -- * Conversion
                      , asList
                      , asPairVector
                      , asVectorPairs
                      -- * Slicing
                      , sliceY
                      , sliceX
                      ) where

import Control.Arrow ((***))
import Control.Monad (ap)
import Data.Array.Vector
import Data.Typeable
import Text.Read
import Text.ParserCombinators.ReadPrec (readPrec_to_S)

import Data.Histogram.Bin
import Data.Histogram.Parse


-- | Immutable histogram. Histogram consists of binning algorithm,
--   optional number of under and overflows, and data. 
data Histogram bin a where
    Histogram :: (Bin bin, UA a) => 
                 bin
              -> Maybe (a,a)
              -> UArr a
              -> Histogram bin a
    deriving Typeable

instance (Show a, Show (BinValue bin), Show bin) => Show (Histogram bin a) where
    show h@(Histogram bin uo _) = "# Histogram\n" ++ showUO uo ++ show bin ++
                                  (unlines $ map showT $ asList h)
        where
          showT (x,y) = show x ++ "\t" ++ show y
          showUO (Just (u,o)) = "# Underflows = " ++ show u ++ "\n" ++
                                "# Overflows  = " ++ show o ++ "\n"
          showUO Nothing      = "# Underflows = \n" ++
                                "# Overflows  = \n"

-- Parse histogram header
histHeader :: (Read bin, Read a, Bin bin, UA a) => ReadPrec (UArr a -> Histogram bin a)
histHeader = do
  keyword "Histogram"
  u   <- maybeValue "Underflows"
  o   <- maybeValue "Overflows"
  bin <- readPrec
  return $ Histogram bin ((,) `fmap` u `ap` o)

-- | Convert String to histogram. Histogram do not have Read instance
--   because of slowness of ReadP
readHistogram :: (Read bin, Read a, Bin bin, UA a) => String -> Histogram bin a
readHistogram str = 
    let (h,rest) = case readPrec_to_S histHeader 0 str of
                     [x] -> x
                     _   -> error "Cannot parse histogram header"
        xs = map (unwords . tail) . filter (not . null) . map words . lines $ rest
    in h (toU $ map read xs)

-- | Read histogram from file.
readFileHistogram :: (Read bin, Read a, Bin bin, UA a) => FilePath -> IO (Histogram bin a)
readFileHistogram fname = readHistogram `fmap` readFile fname

-- | fmap lookalike. It's not possible to create Functor instance
--   because of UA restriction.
mapHist :: UA b => (a -> b) -> Histogram bin a -> Histogram bin b
mapHist f (Histogram bin uo a) = Histogram bin (fmap (f *** f) uo) (mapU f a)

-- FIXME: add some checking. Preferably static.
-- | Apply function to histogram bins. It's expected that function
--   does not change total number of bins. This is not checked.
mapHistBin :: Bin bin' => (bin -> bin') -> Histogram bin a -> Histogram bin' a
mapHistBin f (Histogram bin uo a)
    | nBins bin == nBins bin' = Histogram (f bin) uo a
    | otherwise               = error "Number of bins doesn't match"
    where
      bin' = bin

mapHistData :: UA b => (UArr a -> UArr b) -> Histogram bin a -> Histogram bin b
mapHistData f (Histogram bin uo a) 
    | lengthU b /= lengthU a = error "Array length mismatch"
    | otherwise              = Histogram bin Nothing b
    where 
      b = f a

-- | Histogram bins
histBin :: Histogram bin a -> bin
histBin (Histogram bin _ _) = bin

-- | Histogram data as vector
histData :: Histogram bin a -> UArr a
histData (Histogram _ _ a) = a

-- | Number of underflows
underflows :: Histogram bin a -> Maybe a
underflows (Histogram _ uo _) = fmap fst uo

-- | Number of overflows
overflows :: Histogram bin a -> Maybe a
overflows (Histogram _ uo _) = fmap snd uo

-- | Underflows and overflows
outOfRange :: Histogram bin a -> Maybe (a,a)
outOfRange (Histogram _ uo _) = uo

-- | Convert histogram to list.
asList :: Histogram bin a -> [(BinValue bin, a)]
asList (Histogram bin _ arr) = map (fromIndex bin) [0..] `zip` fromU arr

-- | Convert to pair of vectors
asPairVector :: UA (BinValue bin) => Histogram bin a -> (UArr (BinValue bin), UArr a)
asPairVector (Histogram bin _ a) = (toU $ map (fromIndex bin) [0 .. nBins bin], a)

-- | Convert to vector of pairs
asVectorPairs :: UA (BinValue bin) => Histogram bin a -> UArr ((BinValue bin) :*: a)
asVectorPairs h@(Histogram _ _ _) = uncurry zipU . asPairVector $ h

-- | Slice 2D histogram along Y axis. This function is fast because it does not require reallocations.
sliceY :: (Bin bX, Bin bY) => Histogram (Bin2D bX bY) a -> [(BinValue bY, Histogram bX a)]
sliceY (Histogram b@(Bin2D bX _) _ a) = map mkHist $ init [0, nBins bX .. nBins b]
    where
      mkHist i = ( snd $ fromIndex b i
                 , Histogram bX Nothing (sliceU a i (nBins bX)) )

-- | Slice 2D histogram along X axis.
sliceX :: (Bin bX, Bin bY) => Histogram (Bin2D bX bY) a -> [(BinValue bX, Histogram bY a)]
sliceX (Histogram b@(Bin2D bX bY) _ a) = map mkHist $ init [0 .. nx]
    where
      nx = nBins bX
      n  = nBins b
      mkHist i = ( fst $ fromIndex b i
                 , Histogram bY Nothing (toU $ map (indexU a) [i,i+nx .. n-1]) )
