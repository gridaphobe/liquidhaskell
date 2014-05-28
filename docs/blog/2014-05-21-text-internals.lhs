---
layout: post
title: "Text Internals"
date: 2014-05-21
comments: true
external-url:
author: Eric Seidel
published: true
categories: benchmarks, text
demo: TextInternal.hs
---

So far we have mostly discussed LiquidHaskell in the context of
recursive data structures like lists, but there comes a time in
many programs when you have to put down the list and pick up an
array for the sake of performance.
In this series we're going to examine the `text` library, which
does exactly this in addition to having extensive Unicode support.

`text` is a popular library for efficient text processing.
It provides the high-level API Haskellers have come to expect while
using stream fusion and byte arrays under the hood to guarantee high
performance.

<!--
The thing that makes `text` stand out as an interesting target for
LiquidHaskell, however, is its use of Unicode.
Specifically, `text` uses UTF-16 as its internal encoding, where
each character is represented with either two or four bytes.
We'll see later on how this encoding presents a challenge for
verifying memory-safety, but first let us look at how a `Text`
is represented.

Suppose I want to write a function to get the `Char` at a given index of a
`Text`[^bad].

[^bad]: Disregard for the moment the UTF-8 encoding.
-->

Suppose we wanted to get the *i*th `Char` of a `Text`,
\begin{code} we could write a function[^bad]
charAt (Text a o l) i = word2char $ unsafeIndex a i
  where word2char = chr . fromIntegral
\end{code}
which extracts the underlying array, indexes into it, and casts the `Word16`
to a `Char`, using functions exported by `text`.

[^bad]: This function is bad for numerous reasons, least of which is that `Data.Text.index` is already provided.

\begin{code}Let's try this out in GHCi.
ghci> let t = T.pack ['d','o','g']
ghci> charAt t 0
'd'
ghci> charAt t 2
'g'
\end{code}

\begin{code}Looks good so far, what happens if we keep going?
ghci> charAt t 3
'\NUL'
ghci> charAt t 100
'\8745'
\end{code}

Oh dear, not only did we not get any sort of exception from Haskell, we weren't
even stopped by the OS with a segfault. This is quite dangerous since we have no
idea what sort of data (private keys?) we just read! To be fair to Bryan
O'Sullivan, we did use a function that was clearly marked *unsafe*, but I'd
much rather have the compiler throw an error on these last two calls.

In this post we'll see exactly how prevent invalid memory accesses like this
with LiquidHaskell.
<!-- more -->

<div class="hidden">

\begin{code}
{-# LANGUAGE BangPatterns, CPP, MagicHash, Rank2Types,
    RecordWildCards, UnboxedTuples, ExistentialQuantification #-}
{-@ LIQUID "--no-termination" @-}
module TextInternal (test) where

import qualified Control.Exception as Ex
import Control.Monad.ST.Unsafe (unsafeIOToST)
import Data.Bits (shiftR, xor, (.&.))
import Data.Char
import Foreign.C.Types (CSize)
import GHC.Base (Int(..), ByteArray#, MutableByteArray#, newByteArray#,
                 writeWord16Array#, indexWord16Array#, unsafeCoerce#, ord,
                 iShiftL#)
import GHC.ST (ST(..), runST)
import GHC.Word (Word16(..))

import qualified Data.Text as T
import qualified Data.Text.Internal as T

import Language.Haskell.Liquid.Prelude

{-@ aLen :: a:Array -> {v:Nat | v = (aLen a)}  @-}

{-@ maLen :: a:MArray s -> {v:Nat | v = (maLen a)}  @-}

new          :: forall s. Int -> ST s (MArray s)
unsafeWrite  :: MArray s -> Int -> Word16 -> ST s ()
unsafeFreeze :: MArray s -> ST s Array
unsafeIndex  :: Array -> Int -> Word16
copyM        :: MArray s               -- ^ Destination
             -> Int                    -- ^ Destination offset
             -> MArray s               -- ^ Source
             -> Int                    -- ^ Source offset
             -> Int                    -- ^ Count
             -> ST s ()

{-@ memcpyM :: MutableByteArray# s -> CSize -> MutableByteArray# s -> CSize -> CSize -> IO () @-}
memcpyM :: MutableByteArray# s -> CSize -> MutableByteArray# s -> CSize -> CSize -> IO ()
memcpyM = undefined

--------------------------------------------------------------------------------
--- Helper Code
--------------------------------------------------------------------------------
{-@ shiftL :: i:Nat -> n:Nat -> {v:Nat | ((n = 1) => (v = (i * 2)))} @-}
shiftL :: Int -> Int -> Int
shiftL = undefined -- (I# x#) (I# i#) = I# (x# `iShiftL#` i#)

{-@ pack :: s:String -> {v:Text | (tlen v) = (len s)} @-}
pack :: String -> Text
pack = undefined -- not "actually" using

assert b a = Ex.assert b a
\end{code}

</div>

The `Text` Lifecycle
--------------------
`text` splits the reading and writing array operations between two
types of arrays, immutable `Array`s and mutable `MArray`s. This leads to
the following general lifecycle:

![The lifecycle of a `Text`](/images/text-lifecycle.png)


<!--

Both types carry around with them the number of `Word16`s they can
hold (this is actually only true when you compile with asserts turned
on, but we use this to ease the verification process).
-->

The main four array operations we care about are:

1. **creating** an `MArray`,
2. **writing** into an `MArray`,
3. **freezing** an `MArray` into an `Array`, and
4. **reading** from an `Array`.

Creating an `MArray`
--------------------
The (mutable) `MArray` is a thin wrapper around GHC's primitive
`MutableByteArray#`, additionally carrying the number of `Word16`s it
can store.

\begin{code}
data MArray s = MArray { maBA  :: MutableByteArray# s
                       , maLen :: !Int
                       }
\end{code}

It doesn't make any sense to have a negative length, so we add a
simple refined data definition which states that `maLen` must be
non-negative.

\begin{code}
{-@ data MArray s = MArray { maBA  :: MutableByteArray# s
                           , maLen :: Nat
                           }
  @-}
\end{code}

A nice new side effect of adding this refined data
\begin{code}definition is that we also get the following *accessor measures* for free
measure maBA  :: MArray s -> MutableByteArray# s
measure maLen :: MArray s -> Int
\end{code}

With our free accessor measures in hand, we can start building `MArray`s.
We'll define an `MArrayN n` to be an `MArray` with `n` slots

\begin{code}
{-@ type MArrayN s N = {v:MArray s | (maLen v) = N} @-}
\end{code}

and use it to express that `new n` should return an `MArrayN n`.

\begin{code}
{-@ new :: forall s. n:Nat -> ST s (MArrayN s n) @-}
new n
  | n < 0 || n .&. highBit /= 0 = error "size overflow"
  | otherwise = ST $ \s1# ->
       case newByteArray# len# s1# of
         (# s2#, marr# #) -> (# s2#, MArray marr# n #)
  where !(I# len#) = bytesInArray n
        highBit    = maxBound `xor` (maxBound `shiftR` 1)
        bytesInArray n = n `shiftL` 1
\end{code}

Note that we are not talking
about bytes here, `text` deals with `Word16`s internally and as such
we actualy allocate `2*n` bytes.  While this may seem like a lot of
code to just create an array, the verification process here is quite
simple. LiquidHaskell simply recognizes that the `n` used to construct
the returned array (`MArray marr# n`) is the same `n` passed to
`new`. It should be noted that we're abstracting away some detail here
with respect to the underlying `MutableByteArray#`, specifically we're
making the assumption that any *unsafe* operation will be caught and
dealt with before the `MutableByteArray#` is touched.

Writing into an `MArray`
------------------------
Once we have an `MArray`, we'll want to be able to write our
data into it. Writing into an `MArray` requires a valid index into the
array.

\begin{code}
{-@ unsafeWrite :: ma:MArray s -> MAValidI ma -> Word16 -> ST s () @-}
\end{code}

A valid index into an `MArray` is a `Nat` that is *strictly* less than
the length of the array.

\begin{code}
{-@ type MAValidI MA = {v:Nat | v < (maLen MA)} @-}
\end{code}

`text` checks this property at run-time, but LiquidHaskell
can statically prove that the error branch is unreachable.

\begin{code}
unsafeWrite MArray{..} i@(I# i#) (W16# e#)
  | i < 0 || i >= maLen = liquidError "out of bounds"
  | otherwise = ST $ \s1# ->
      case writeWord16Array# maBA i# e# s1# of
        s2# -> (# s2#, () #)
\end{code}

So now we can write individual `Word16`s into an array, but maybe we
have a whole bunch of text we want to dump into the array. Remember,
`text` is supposed to be fast!
C has `memcpy` for cases like this but it's notoriously unsafe; with
the right type however, we can regain safety. `text` provides a wrapper around
`memcpy` to copy `n` elements from one `MArray` to another.

`copyM` requires two `MArray`s and valid offsets into each -- note
that a valid offset is **not** necessarily a valid *index*, it may
be one element out-of-bounds

\begin{code}
{-@ type MAValidO MA = {v:Nat | v <= (maLen MA)} @-}
\end{code}

-- and a `count` of elements to copy.
The `count` must represent a valid region in each `MArray`, in
other words `offset + count <= length` must hold for each array.

\begin{code}
{-@ copyM :: dest:MArray s
          -> didx:MAValidO dest
          -> src:MArray s
          -> sidx:MAValidO src
          -> {v:Nat | (((didx + v) <= (maLen dest))
                    && ((sidx + v) <= (maLen src)))}
          -> ST s ()
  @-}
copyM dest didx src sidx count
    | count <= 0 = return ()
    | otherwise =
    assert (sidx + count <= maLen src) .
    assert (didx + count <= maLen dest) .
    unsafeIOToST $ memcpyM (maBA dest) (fromIntegral didx)
                           (maBA src) (fromIntegral sidx)
                           (fromIntegral count)
\end{code}

You might notice the two `assert`s in the function, they were in the
original code as run-time checks of the precondition, but LiquidHaskell
can actually *prove* that the `assert`s **cannot** fail, we just have
to give `assert` the type

\begin{code}
{-@ assert assert :: {v:Bool | (Prop v)} -> a -> a @-}
\end{code}

Freezing an `MArray` into an `Array`
------------------------------------
Before we can package up our `MArray` into a `Text`, we need to
*freeze* it, preventing any further mutation. The key property here is
of course that the frozen `Array` should have the same length as the
`MArray`.

Just as `MArray` wraps a mutable array, `Array` wraps an *immutable*
`ByteArray#` and carries its length in `Word16`s.

\begin{code}
data Array = Array { aBA  :: ByteArray#
                   , aLen :: !Int
                   }
\end{code}

As before, we get free accessor measures `aBA` and `aLen` just by
refining the data definition

\begin{code}
{-@ data Array = Array { aBA  :: ByteArray#
                       , aLen :: Nat
                       }
  @-}
\end{code}

so we can refer to the components of an `Array` in our refinements.
Using these measures, we can define

\begin{code}
{-@ type ArrayN N = {v:Array | (aLen v) = N} @-}
{-@ unsafeFreeze :: ma:MArray s -> ST s (ArrayN (maLen ma)) @-}
unsafeFreeze MArray{..} = ST $ \s# ->
                          (# s#, Array (unsafeCoerce# maBA) maLen #)
\end{code}

Again, LiquidHaskell is happy to prove our specification as we simply
copy the length parameter `maLen` over into the `Array`.

Reading from an `Array`
------------------------
Finally, we will eventually want to read a value out of the
`Array`. As with `unsafeWrite` we require a valid index into the
`Array`, which we denote using the `AValidI` alias.

\begin{code}
{-@ type AValidI A = {v:Nat | v < (aLen A)} @-}
{-@ unsafeIndex :: a:Array -> AValidI a -> Word16 @-}
unsafeIndex Array{..} i@(I# i#)
  | i < 0 || i >= aLen = liquidError "out of bounds"
  | otherwise = case indexWord16Array# aBA i# of
                  r# -> (W16# r#)
\end{code}

As before, LiquidHaskell can easily prove that the error branch
is unreachable!

Wrapping it all up
------------------
Now we can finally define the core datatype of the `text` package!
A `Text` value consists of an *array*, an *offset*, and a *length*.

\begin{code}
data Text = Text Array Int Int
\end{code}

**ES**: still need to fix up this text..

The offset and length are `Nat`s satisfying two properties:

1. `off <= aLen arr`, and
2. `off + len <= aLen arr`

\begin{code}
{-@ type TValidO A   = {v:Nat | v     <= (aLen A)} @-}
{-@ type TValidL O A = {v:Nat | (v+O) <= (aLen A)} @-}

{-@ data Text = Text { tarr :: Array
                     , toff :: TValidO tarr
                     , tlen :: TValidL toff tarr
                     }
  @-}
\end{code}

These invariants ensure that any *index* we pick between `off` and
`off + len` will be a valid index into `arr`. If you're not quite
convinced, consider the following `Text`s.

![the layout of multiple Texts](/images/text-layout.png)
<div style="width:80%; text-align:center; margin:auto; margin-bottom:1em;"><p>Multiple valid <code>Text</code> configurations, all using an <code>Array</code> with 10 slots. The valid slots are shaded. Note that the key invariant is that <code>off + len <= aLen</code>.</p></div>


Now let's take a quick step back and recall the example
that motivated this whole discussion.

\begin{code}
{-@ charAt :: t:Text -> {v:Nat | v < (tlen t)} -> Char @-}
charAt (Text a o l) i = word2char $ unsafeIndex a i
  where word2char = chr . fromIntegral


test = [good,bad]
  where
    dog = ['d','o','g']
    bad = charAt (pack dog) 4
    good = charAt (pack dog) 2
\end{code}

Fantastic! LiquidHaskell is telling us that our call to
`unsafeIndex` is, in fact, **unsafe** because we don't know
that `i` is a valid index.

Phew, that was a lot for one day, next time we'll take a look at how to handle
uncode in `text`.

