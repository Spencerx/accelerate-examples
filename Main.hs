
module Main where

import MD5
import Digest
import Config

import Numeric
import Data.List
import Data.Label
import Text.Printf
import Control.Monad
import Criterion.Measurement
import System.IO
import System.Environment
import Data.Array.Accelerate                    ( Z(..), (:.)(..) )
import qualified Data.Array.Accelerate          as A
import qualified Data.ByteString.Lazy.Char8     as L

--import Data.Serialize                           as S




{--
v = L.pack $ map c2w "password"
c = defaultConfig

main = do
  dict  <- digest c v

  let r = (`A.indexArray` (Z:.0)) $ run c $ md5 (A.use dict)

  print r
  putStrLn $ showMD5 r


import Data.Array.Accelerate
import Text.Printf


-- "hello, world."
--
-- MD5 ("hello, world.") = 708171654200ecd0e973167d8826159c
--
helloworld :: [Word32]
helloworld =
  [0x68656c6c, 0x6f2c2077, 0x6f726c64, 0x2e800000
  ,0x00000000, 0x00000000, 0x00000000, 0x00000000
  ,0x00000000, 0x00000000, 0x00000000, 0x00000000
  ,0x00000000, 0x00000000, 0x00000000, 0x68000000 ]

helloworld' :: [Word32]
helloworld' = [1819043176,1998597231,1684828783,32814,0,0,0,0,0,0,0,0,0,0,104,0]

main :: IO ()
main =
  let word      = use $ fromList (Z:.16:.1) helloworld'
      res       = run $ md5 word

      (x,y,z,w) = res `indexArray` (Z:.0)
  in
  printf "%x%x%x%x\n" x y z w
--}



main :: IO ()
main = do
  (conf, _cconf, _nops) <- parseArgs =<< getArgs

  -- Read the plain text word lists. This creates a vector of MD5 chunks ready
  -- for hashing. Since we use Accelerate for the final processing stage, this
  -- will already be resident on compute device.
  --
  putStr "reading wordlist... " >> hFlush stdout
  (tdict, dict) <- time $ runDigest conf =<< digestFiles (get configWordlist conf)

  let (Z :. _ :. entries) = A.arrayShape dict
  putStrLn $ printf "%d words in %s\n" entries (secs tdict)

  -- Attempt to recover one hash at a time by comparing it to entries in the
  -- database. This rehashes the entire word list every time, rather than
  -- pre-computing the hashes and performing a lookup. That approach, known as a
  -- rainbow table, while much faster when multiple iterations of the hashing
  -- function are applied, but is defeated by salting passwords. This is true
  -- even if the salt is known, so long as it is unique for each password.
  --
  let recover hash =
        let abcd = readMD5 hash
            idx  = run1 conf (hashcat (A.use dict)) (A.fromList Z [abcd])
        --
        in case idx `A.indexArray` Z of
             -1 -> Nothing
             n  -> Just (extract dict n)

      recoverAll :: [L.ByteString] -> IO (Int,Int)
      recoverAll =
        foldM (\(i,n) h -> maybe (return (i,n+1)) (\t -> showText h t >> return (i+1,n+1)) (recover h)) (0,0)

      showText hash text = do
        L.putStr hash >> putStr " = \"" >> L.putStr text >> putStrLn "\""

  digests <- case get configDigests conf of
               Right s  -> return [L.pack s]
               Left fs  -> concat `fmap` mapM (\f -> L.lines `fmap` L.readFile f) fs

  -- Run the lookup for each unknown hash against the given wordlists.
  --
  putStrLn "beginning recovery..."
  (trec, (r, t)) <- time (recoverAll digests)

  -- And print a summary of results
  --
  let percent = fromIntegral r / fromIntegral t * 100.0 :: Double
      persec  = fromIntegral (t * entries) / trec
  putStrLn $ printf "\nrecovered %d/%d (%f %%) digests in %s, %s"
                      r t percent (secs trec)
                      (showFFloatSIBase (Just 2) 1000 persec "Hash/sec")

  when (r == t) $ putStrLn "All hashes recovered (:"


showFFloatSIBase :: RealFloat a => Maybe Int -> a -> a -> ShowS
showFFloatSIBase p b n
  = showString
  . nubBy (\x y -> x == ' ' && y == ' ')
  $ showFFloat p n' [ ' ', si_unit ]
  where
    n'          = n / (b ^^ (pow-4))
    pow         = max 0 . min 8 . (+) 4 . floor $ logBase b n
    si_unit     = "pnµm kMGT" !! pow

