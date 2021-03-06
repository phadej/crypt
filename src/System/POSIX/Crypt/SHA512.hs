{-# LANGUAGE OverloadedStrings #-}
module System.POSIX.Crypt.SHA512 (
    cryptSHA512,
    cryptSHA512',
    cryptSHA512Raw,
    -- * Utilities
    encode64,
    encode64List,
    ) where

import Control.Applicative (optional)
import Data.Bits           (shiftL, shiftR, (.&.), (.|.))
import Data.List           (foldl')
import Data.String         (fromString)
import Data.Word           (Word32, Word8)

import qualified Crypto.Hash.SHA512               as SHA
import qualified Data.Attoparsec.ByteString       as A
import qualified Data.Attoparsec.ByteString.Char8 as A8
import qualified Data.ByteString                  as BS

{-
import qualified Data.ByteString.Base16 as Base16
import Debug.Trace

traceBSId :: String -> BS.ByteString -> BS.ByteString
traceBSId n dig = trace (n ++ ": " ++ show (Base16.encode dig)) dig
-}

traceBSId :: String -> BS.ByteString -> BS.ByteString
traceBSId _ = id

-- | Pure Haskell implementation of SHA512 @crypt@ method.
--
-- For @libc@ versions supporting SHA512 encryption scheme (6):
--
-- prop> "$6$" `isPrefixOf` salt ==> crypt key salt = cryptSHA512 key salt
--
-- === a snippet from glibc documentation
--
-- @glibc@ implementations of @crypt@ support additional encryption algorithms.
--
-- If /salt/ is a character string starting with the characters @"$id$"@ followed by a string terminated by @"$"@:
--
-- @
-- \$id$salt$encrypted
-- @
--
-- then instead of using the DES machine, id identifies the encryption method used and this then determines how the rest of the password  string  is  interpreted.
--
-- The @id@ value @6@ corresponds to SHA-512 method (since @glibc-2.17@).
--
-- If the /salt/ string starts with
--
-- @
-- rounds=\<N>$
-- @
--
-- where /N/ is an unsigned decimal number the numeric value of /N/ is used
--to modify the algorithm used. For example:
--
-- @
-- \$6$rounds=77777$salt$encrypted
-- @
--
-- See <https://www.akkadia.org/drepper/SHA-crypt.txt>
--
cryptSHA512
    :: BS.ByteString  -- ^ key
    -> BS.ByteString  -- ^ salt: @$6$...@
    -> Maybe BS.ByteString
cryptSHA512 key saltI = case A.parseOnly saltP saltI of
    Left _               -> Nothing
    Right (salt, rounds) -> Just (cryptSHA512Raw rounds key salt)
  where
    saltP :: A.Parser (BS.ByteString, Maybe Int)
    saltP = do
        _ <- A.string header
        rounds <- optional roundsP
        salt <- A.takeWhile (/= 36) -- ord '$' = 36
        return (BS.take 16 salt, rounds)

    roundsP :: A.Parser Int
    roundsP = do
        _ <- A.string "rounds="
        n <- A8.decimal
        _ <- A.word8 36
        return n

-- | Split salt-input variant of 'cryptSHA512'. Salt is encoded.
cryptSHA512'
    :: Maybe Int      -- ^ rounds
    -> BS.ByteString  -- ^ key
    -> BS.ByteString  -- ^ salt, will be base64 encoded
    -> BS.ByteString
cryptSHA512' rounds key salt = cryptSHA512Raw rounds key (encode64 salt)

-- | Raw input implementation of 'cryptSHA512'.
cryptSHA512Raw
    :: Maybe Int      -- ^ rounds, clamped into @[1000, 999999999]@ range
    -> BS.ByteString  -- ^ key
    -> BS.ByteString  -- ^ salt, first 16 characters used.
    -> BS.ByteString
cryptSHA512Raw Nothing key salt' =
    let salt = BS.take 16 salt'
        enc  = implementation 5000 key salt
    in BS.concat
        [ header
        , salt
        , "$"
        , encode64' enc
        ]
cryptSHA512Raw (Just n) key salt' =
    let rounds = min 999999999 $ max 1000 n
        salt   = BS.take 16 salt'
        enc    = implementation rounds key salt
    in BS.concat
        [ header
        , "rounds="
        , fromString (show rounds)
        , "$"
        , salt
        , "$"
        , encode64' enc
        ]

header :: BS.ByteString
header = "$6$"

implementation
    :: Int            -- ^ rounds
    -> BS.ByteString  -- ^ key
    -> BS.ByteString  -- ^ salt
    -> BS.ByteString
implementation roundsN key salt =
       -- steps 4-8
    let digB = traceBSId "digest B" $
            SHA.finalize $ SHA.updates SHA.init [key, salt, key]

        -- steps 1-3
        ctxA0 = SHA.updates SHA.init [key, salt]

        -- steps 9-10
        ctxA1 = fl keyblocks ctxA0 $ \ctx block ->
            if BS.length block == 64
                then SHA.update ctx digB
                else SHA.update ctx (BS.take (BS.length block) digB)

        -- step 11
        ctxA2 = fl (bits (BS.length key)) ctxA1 $ \ctx one ->
            if one
                then SHA.update ctx digB
                else SHA.update ctx key

        -- step 12
        digA = traceBSId "digest A" $
            SHA.finalize ctxA2

        -- steps 13-15
        digDP = traceBSId "digest DP" $
            SHA.finalize $ SHA.updates SHA.init $
                replicate (BS.length key) key

        -- step 16
        p = traceBSId "byte sequence P" $
            BS.concat $ flip map keyblocks $ \block ->
                BS.take (BS.length block) digDP

        -- steps 17-19
        digDS = traceBSId "digest DS" $
            SHA.finalize $ rounds (16 + fromIntegral (BS.index digA 0)) SHA.init $ \ctx ->
                SHA.update ctx salt

        -- step 20
        s = traceBSId "byte sequence S" $
            BS.concat $ flip map saltblocks $ \block ->
                BS.take (BS.length block) digDS

        -- step 21
        enc = rounds' roundsN digA $ \i digAC ->
                -- a) start digest C
            let ctxC0 = SHA.init

                -- b) for odd round numbers add the byte sequense P to digest C
                -- c) for even round numbers add digest A/C
                ctxC1 = if i `mod` 2 /= 0
                    then SHA.update ctxC0 p
                    else SHA.update ctxC0 digAC

                -- d) for all round numbers not divisible by 3 add the byte sequence S
                ctxC2 = if i `mod` 3 /= 0 then SHA.update ctxC1 s else ctxC1

                -- e) for all round numbers not divisible by 7 add the byte sequence P
                ctxC3 = if i `mod` 7 /= 0 then SHA.update ctxC2 p else ctxC2

                -- f) for odd round numbers add digest A/C
                -- g) for even round numbers add the byte sequence P
                ctxC4 = if i `mod` 2 /= 0
                    then SHA.update ctxC3 digAC
                    else SHA.update ctxC3 p

                -- h) finish digest C.
            in SHA.finalize ctxC4
    in enc
  where
    -- blocks of 64 bytes!
    keyblocks :: [BS.ByteString]
    keyblocks = splitMany key

    saltblocks :: [BS.ByteString]
    saltblocks = splitMany salt

    splitMany bs
        | BS.null bs = []
        | otherwise  = let (a, b) = BS.splitAt 64 bs in a : splitMany b

    -- foldl' with parameters reversed
    fl xs i f = foldl' f i xs

    bits :: Int -> [Bool]
    bits n
        | n <= 0    = []
        | otherwise = let (m, d) = n `divMod` 2 in (d == 1) : bits m

    rounds :: Int -> a -> (a -> a) -> a
    rounds n x f = rounds' n x (const f)

    -- rounds variant with a step
    rounds' :: Int -> a -> (Int -> a -> a) -> a
    rounds' n x f = go 0 x where
        go i y | i < n     = y `seq` go (i+1) (f i y)
               | otherwise = y

-------------------------------------------------------------------------------
-- Custom Base64 encoding
-------------------------------------------------------------------------------

-- | Custom base64 encoding used by crypt SHA512 scheme.
encode64 :: BS.ByteString -> BS.ByteString
encode64 = encode64List . BS.unpack

-- | Custom base64 encoding used by crypt SHA512 scheme. See 'encode64'.
encode64List :: [Word8] -> BS.ByteString
encode64List = BS.pack . go
  where
    go :: [Word8] -> [Word8]
    go []  = []
    go [b] =
        [ BS.index alphabet $ fromIntegral $ b .&. 0x3f
        , BS.index alphabet $ fromIntegral $ b `shiftR` 6
        ]
    go [b1, b0] =
        [ BS.index alphabet $ fromIntegral $ w .&. 0x3f
        , BS.index alphabet $ fromIntegral $ w `shiftR` 6 .&. 0x3f
        , BS.index alphabet $ fromIntegral $ w `shiftR` 12 .&. 0x3f
        ]
      where
        w :: Word32
        w = fromIntegral b0 .|. fromIntegral b1 `shiftL` 8
    go (b2:b1:b0:bs) =
        BS.index alphabet (fromIntegral $ w .&. 0x3f) :
        BS.index alphabet (fromIntegral $ w `shiftR` 6 .&. 0x3f) :
        BS.index alphabet (fromIntegral $ w `shiftR` 12 .&. 0x3f) :
        BS.index alphabet (fromIntegral $ w `shiftR` 18 .&. 0x3f) :
        go bs
      where
        w :: Word32
        w = fromIntegral b0
            .|. fromIntegral b1 `shiftL` 8
            .|. fromIntegral b2 `shiftL` 16

    alphabet :: BS.ByteString
    alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

encode64'
    :: BS.ByteString  -- should be 64 word8 long!
    -> BS.ByteString
encode64' bs | BS.length bs /= 64 =
    error $ "System.POSIX.Crypt.SHA512.encode64': input should be 64 in length: " ++ show (BS.length bs)
encode64' bs = encode64List
    [ i  0, i 21, i 42
    , i 22, i 43, i  1
    , i 44, i  2, i 23
    , i  3, i 24, i 45
    , i 25, i 46, i  4
    , i 47, i  5, i 26
    , i  6, i 27, i 48
    , i 28, i 49, i  7
    , i 50, i  8, i 29
    , i  9, i 30, i 51
    , i 31, i 52, i 10
    , i 53, i 11, i 32
    , i 12, i 33, i 54
    , i 34, i 55, i 13
    , i 56, i 14, i 35
    , i 15, i 36, i 57
    , i 37, i 58, i 16
    , i 59, i 17, i 38
    , i 18, i 39, i 60
    , i 40, i 61, i 19
    , i 62, i 20, i 41
    , i 63
    ]
  where
    i = BS.index bs
