{-# LANGUAGE TemplateHaskell #-}
module Main where

import Language.Haskell.TH

main :: IO ()
main = putStrLn $(litE (stringL "template haskell works"))
