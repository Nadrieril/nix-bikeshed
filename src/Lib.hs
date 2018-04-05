module Lib (indent) where

import Nix.Expr
import Nix.Parser

doTheThing :: IO ()
doTheThing = putStrLn $ indent $ parse "/proc/self/fd/1"

parse :: FilePath -> NExpr
parse f = do
    expr <- parseNixFile f
    case expr of
        Success a -> a
        Failure e -> error $ show e

indent :: NExpr -> String
indent a = "someFunc"
