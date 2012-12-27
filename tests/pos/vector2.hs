module Vec0 where

import Prelude hiding (length)

import Data.Vector
    
{-@ predicate Lt x y      = x < y                         @-}
{-@ predicate Ge x y      = not (Lt x y)                  @-}
{-@ predicate InBound i a = ((Ge i 0) && (Lt i (vlen a))) @-}

{-@ unsafeLookup :: vec:Vector a 
                 -> {v: Int | (0 <= v && v < (vlen vec)) } 
                 -> a @-}
unsafeLookup vec i = vec ! i

{-@ unsafeLookup' :: vec:Vector a -> {v: Int | (InBound v vec)} -> a @-}
unsafeLookup' vec i = vec ! i

safeLookup x i 
  | 0 <= i && i < length x = Just (x ! i)
  | otherwise              = Nothing 

{-@ absoluteSum   :: Vector Int -> {v: Int | 0 <= v}  @-}
absoluteSum       :: Vector Int -> Int 
absoluteSum vec   = if 0 < n then go 0 0 else 0
  where
    go acc i 
      | i /= n    = go (acc + abz (vec ! i)) (i + 1)
      | otherwise = acc 
    n             = length vec

abz n = if 0 <= n then n else (0 - n) 

loop :: Int -> Int -> a -> (Int -> a -> a) -> a 
loop lo hi base f = go base lo
  where
    go acc i     
      | i /= hi   = go (f i acc) (i + 1)
      | otherwise = acc

incr x = x + 1

zoo = incr 29

{- type SparseVector a n = [({v: Int | (Btwn 0 v n)}, a)] @-}

{- sparseDotProduct :: (Num a) => x:(Vector a) -> (SparseVector a (vlen x)) -> a @-}
-- sparseDotProduct x y  = go 0 y
--   where 
--     go sum ((i, v) : y') = go (sum + (x ! i) * v) y' 
--     go sum []            = sum

