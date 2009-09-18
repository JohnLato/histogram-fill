{-# LANGUAGE GADTs #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE Rank2Types #-}
-- |
-- Module     : Data.Histogram.ST
-- Copyright  : Copyright (c) 2009, Alexey Khudyakov <alexey.skladnoy@gmail.com>
-- License    : BSD3
-- Maintainer : Alexey Khudyakov <alexey.skladnoy@gmail.com>
-- Stability  : experimental
-- 
-- Mutable histograms.

module Data.Histogram.ST ( -- * Mutable histograms
                           HistogramST(..)
                         , newHistogramST
                         , fillOne
                         , fillOneW
                         , fillMonoid
                         , freezeHist

                         -- * Accumulators
                         , Accumulator(..)
                         , Accum(Accum)

                         , accumList
                         , accumHist

                         , fillHistograms
                         ) where


import Control.Monad.ST

import Data.Array.Vector
import Data.Monoid

import Data.Histogram
import Data.Histogram.Bin


----------------------------------------------------------------
-- Mutable histograms
----------------------------------------------------------------

-- | Mutable histogram.
data HistogramST s bin a where
    HistogramST :: (Bin bin, UA a) => 
                   bin
                -> MUArr a s -- Over/underflows
                -> MUArr a s -- Data
                -> HistogramST s bin a

-- | Create new mutable histogram. All bins are set to zero element as
--   passed to function.
newHistogramST :: (Bin bin, UA a) => a -> bin -> ST s (HistogramST s bin a)
newHistogramST zero bin = do
  uo <- newMU 2
  writeMU uo 0 zero >> writeMU uo 1 zero
  a <- newMU (nBins bin)
  mapM_ (\i -> writeMU a i zero) [0 .. (lengthMU a) - 1]
  return $ HistogramST bin uo a

-- | Put one value into histogram
fillOne :: Num a => HistogramST s bin a -> BinValue bin -> ST s ()
fillOne (HistogramST bin uo arr) x
    | i < 0             = writeMU uo  0 . (+1)  =<< readMU uo 0
    | i >= lengthMU arr = writeMU uo  1 . (+1)  =<< readMU uo 1
    | otherwise         = writeMU arr i . (+1)  =<< readMU arr i
    where
      i = toIndex bin x

-- | Put one value into histogram with weight
fillOneW :: Num a => HistogramST s bin a -> (BinValue bin, a) -> ST s ()
fillOneW (HistogramST bin uo arr) (x,w)
    | i < 0             = writeMU uo  0 . (+w)  =<< readMU uo 0
    | i >= lengthMU arr = writeMU uo  1 . (+w)  =<< readMU uo 1
    | otherwise         = writeMU arr i . (+w)  =<< readMU arr i
    where
      i = toIndex bin x

-- | Put one monoidal element
fillMonoid :: Monoid a => HistogramST s bin a -> (BinValue bin, a) -> ST s ()
fillMonoid (HistogramST bin uo arr) (x,m)
    | i < 0             = writeMU uo  1 . (flip mappend m)  =<< readMU uo  0
    | i >= lengthMU arr = writeMU uo  1 . (flip mappend m)  =<< readMU uo  1
    | otherwise         = writeMU arr i . (flip mappend m)  =<< readMU arr i
    where
      i = toIndex bin x

-- | Create immutable histogram from mutable one. This operation involve copying.
freezeHist :: HistogramST s bin a -> ST s (Histogram bin a)
freezeHist (HistogramST bin uo arr) = do
  [u,o] <- fromU `fmap` unsafeFreezeAllMU uo -- Is it safe???
  -- Copy array
  let len = lengthMU arr
  tmp  <- newMU len
  memcpyOffMU arr tmp 0 0 len
  a    <- unsafeFreezeAllMU tmp
  return $ Histogram bin (Just (u,o)) a



----------------------------------------------------------------
-- Accumulator typeclass
----------------------------------------------------------------
-- | This is class with accumulation semantics. It's used to fill many
--   histogram at once. It accept values of type a and return data of type b.
class Accumulator h where
    -- | Put one element into accumulator
    putOne  :: h s a b -> a   -> ST s () 
    -- | Extract data from historam
    extract :: Monoid b => (h s a b) -> ST s b

-- | Put many elements in histogram(s) at once 
putMany :: Accumulator h => h s a b -> [a] -> ST s () 
putMany !h = mapM_ (putOne h) 

-- | Put all values into histogram and return result
fillHistograms :: Monoid b => (forall s . ST s (Accum s a b)) -> [a] -> b
fillHistograms h xs = runST $ do h' <- h
                                 putMany h' xs
                                 extract h'

----------------------------------------------------------------
-- GADT wrapper 
----------------------------------------------------------------
-- | Abstract wrapper for histograms. 
data Accum s a b where
    Accum :: Accumulator h => h s a b -> Accum s a b

instance Accumulator Accum where
    putOne  !(Accum h) !x = putOne h x 
    extract !(Accum h)    = extract h


----------------------------------------------------------------
-- List of histograms
----------------------------------------------------------------
newtype AccumList s a b = AccumList [Accum s a b]
 
-- | Wrap list of histograms into one 'Accum'
accumList :: [ST s (Accum s a b)] -> ST s (Accum s a b)
accumList l = (Accum . AccumList) `fmap` sequence l

instance Accumulator AccumList where
    putOne  !(AccumList l) !x = mapM_ (flip putOne $ x) l 
    extract !(AccumList l)    = mconcat `fmap` mapM extract l 


----------------------------------------------------------------
-- Generic histogram 
----------------------------------------------------------------
data AccumHist s a b where
    AccumHist :: (Bin bin) =>
                 (a -> HistogramST s bin val -> ST s ())
              -> (Histogram bin val -> b)
              -> HistogramST s bin val
              -> AccumHist s a b

-- | Accumulator for arbitrary 'HistogramST' based histogram
accumHist :: (Bin bin) =>
             (a -> HistogramST s bin val -> ST s ())
          -> (Histogram bin val -> b)
          -> HistogramST s bin val
          -> ST s (Accum s a b)
accumHist inp out h = return . Accum $ AccumHist inp out h

instance Accumulator AccumHist where
    putOne  !(AccumHist inp _ st) !x = inp x st
    extract !(AccumHist _ out st)    = out `fmap` freezeHist st