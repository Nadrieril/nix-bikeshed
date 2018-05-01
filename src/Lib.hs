{-# LANGUAGE FlexibleInstances, TypeSynonymInstances, RankNTypes #-}
module Lib where

import Control.Monad.State.Strict
import Control.Monad.Writer.Strict
import Control.Monad.Zip

import Data.Fix
import Data.List
import qualified Data.Map as M
import qualified Data.Text as T

import Debug.Trace

import Nix.Atoms
import Nix.Expr
import Nix.Parser
import Nix.Pretty
import qualified Nix.Parser.Operators as Nix

maxLineLength = 80

doTheThing :: String -> Bool -> IO ()
doTheThing file check = do
    expr <- parseFile file
    let indented = indentExpr maxLineLength expr;
    if check then do
        let check = parseStr indented;
        if expr `isEquivalentTo` check then
            putStrLn indented
        else
            error ("Unable to check the result: AST mismatch between\n" ++
                   "Source: " ++ show expr ++ "\n" ++
                   "Indented: " ++ show check ++ "\n")
    else
        putStrLn indented

parseFile :: FilePath -> IO NExpr
parseFile f = do
    expr <- parseNixFile f
    case expr of
        Success a -> return a
        Failure e -> error $ show e

parseStr :: String -> NExpr
parseStr s = case parseNixString s of
    Success a -> a
    Failure e -> error $ show e

newtype WrapNExpr = WrapNExpr NExpr
instance Eq WrapNExpr where
    (WrapNExpr a) == (WrapNExpr b) = a `isEquivalentTo` b
isEquivalentTo :: NExpr -> NExpr -> Bool
isEquivalentTo (Fix a) (Fix b) = case (fmap WrapNExpr a, fmap WrapNExpr b) of
    (NStr a, NStr b) -> stringContent a == stringContent b
        where
            stringContent a = case a of
                Indented x -> x
                DoubleQuoted x -> x
    (a, b) -> a == b


class Monad m => IndentMonad m where
    appendLine :: String -> m ()
    newLine :: m ()
    indent :: m a -> m a
    hasSpaceFor :: Int -> m Bool

-- If there is enough space on the line, run (x True), otherwise run (x False)
-- In CountMonad, this simply runs (x True)
tryOneLine :: forall m. IndentMonad m => (forall n. IndentMonad n => Bool -> n ()) -> m ()
tryOneLine x = hasSpaceFor (runCountMonad (x True)) >>= x

data WriteItem = WriteItem
    { isNewLine :: Bool
    , lineBegin :: String
    , text :: String }
type ColumnInfo = (Int, Int) -- (current column, maximal column)

type NixMonad = WriterT [WriteItem] (State ColumnInfo)

runNixMonad :: Int -> NixMonad () -> [WriteItem]
runNixMonad maximalLineLength m = evalState (execWriterT m) (0, maximalLineLength)

instance IndentMonad NixMonad where
    appendLine x = do
        tell [WriteItem { isNewLine = False, lineBegin = "", text = x }]
        (col, max) <- get
        put $ (col + length x, max)

    newLine = do
        tell [WriteItem { isNewLine = True, lineBegin = "", text = "" }]
        (_, max) <- get
        put $ (0, max)

    indent x = do
        (col, max) <- get
        put $ (col + 2, max)
        res <- flip censor x $ fmap $ \x -> x { lineBegin = "  " ++ lineBegin x }
        put $ (col, max)
        return res

    hasSpaceFor x = do
        (col, max) <- get
        return (col + x <= max)


type CountMonad = Writer (Sum Int)

runCountMonad :: CountMonad () -> Int
runCountMonad = getSum . execWriter

instance IndentMonad CountMonad where
    appendLine x = tell (Sum $ length x)
    newLine = return ()
    indent x = x
    hasSpaceFor x = return True

noop :: Monad m => m ()
noop = return ()

intercalateM :: Monad m => m () -> [m ()] -> m ()
intercalateM v l = sequence_ $ intersperse v l

indentExpr :: Int -> NExpr -> String
indentExpr maximalLineLength a =
    let nix = runNixMonad maximalLineLength (exprI a) in
    concatMap (\wi ->
        (if isNewLine wi then "\n" ++ lineBegin wi else "") ++ text wi
    ) nix

-- *I functions return the string that fits the constraints
exprI :: IndentMonad m => NExpr -> m ()
exprI (Fix expr) = case expr of
    NConstant c -> atomI c
    NStr s -> stringI s
    NSym s -> appendLine $ T.unpack s
    NList vals -> listI vals
    NSet binds -> setI False binds
    NRecSet binds -> setI True binds
    NLiteralPath p -> appendLine p
    NEnvPath p -> appendLine $ "<" ++ p ++ ">"
    NUnary op ex -> unaryOpI op ex
    NBinary op l r -> binaryOpI op l r
    NSelect set attr def -> selectI set attr def
    NHasAttr set attr -> hasAttrI set attr
    NAbs param expr -> absI param expr
    NApp f x -> appI f x
    NLet binds ex -> letI binds ex
    NIf cond then_ else_ -> ifI cond then_ else_
    NWith set expr -> stmtI "with" set expr
    NAssert test expr -> stmtI "assert" test expr

-- *L functions return the length the expression would take if put all on one
-- line
exprL :: NExpr -> Int
exprL = runCountMonad . exprI


data Prio
    = NoPrio
    | HNixPrio Nix.OperatorInfo
    | MaxPrio

instance Eq Prio where
    NoPrio == NoPrio = True
    MaxPrio == MaxPrio = True
    HNixPrio x == HNixPrio y =
        Nix.precedence x == Nix.precedence y
    _ == _ = False

instance Ord Prio where
    NoPrio `compare` NoPrio = EQ
    NoPrio `compare` _ = LT
    MaxPrio `compare` MaxPrio = EQ
    MaxPrio `compare` _ = GT
    _ `compare` NoPrio = GT
    _ `compare` MaxPrio = LT
    HNixPrio x `compare` HNixPrio y =
        Nix.precedence y `compare` Nix.precedence x

binOpOf :: Prio -> String
binOpOf (HNixPrio op) = Nix.operatorName op

binOpStr :: NBinaryOp -> String
binOpStr = Nix.operatorName . Nix.getBinaryOperator

unOpStr :: NUnaryOp -> String
unOpStr = Nix.operatorName . Nix.getUnaryOperator

-- Less binds stronger
exprPrio :: NExpr -> Prio
exprPrio (Fix expr) = case expr of
    -- See https://nixos.org/nix/manual/#table-operators
    NSelect _ _ _ -> selectPrio
    NApp _ _ -> appPrio
    NUnary op _ -> unaryPrio op
    NHasAttr _ _ -> hasAttrPrio
    NBinary op _ _ -> binaryPrio op
    NAbs _ _ -> MaxPrio
    NLet _ _ -> MaxPrio
    NIf _ _ _ -> MaxPrio
    NWith _ _ -> MaxPrio
    NAssert _ _ -> MaxPrio
    _ -> NoPrio

listPrio, appPrio, selectPrio, hasAttrPrio :: Prio
listPrio = HNixPrio Nix.appOp
appPrio = HNixPrio Nix.appOp
selectPrio = HNixPrio Nix.selectOp
hasAttrPrio = HNixPrio Nix.hasAttrOp

unaryPrio :: NUnaryOp -> Prio
unaryPrio = HNixPrio . Nix.getUnaryOperator
binaryPrio :: NBinaryOp -> Prio
binaryPrio = HNixPrio . Nix.getBinaryOperator


associates :: Prio -> Prio -> Bool
associates l r = case (binOpOf l, binOpOf r) of
    -- *, /
    ("*", "*") -> True
    ("*", "/") -> True
    ("/", "*") -> False
    ("/", "/") -> False
    -- +, -
    ("+", "+") -> True
    ("+", "-") -> True
    ("-", "+") -> False
    ("-", "-") -> False
    -- ==, !=
    ("==", "==") -> False
    ("==", "!=") -> False
    ("!=", "==") -> False
    ("!=", "!=") -> False
    -- //
    ("//", "//") -> True

paren :: IndentMonad m => m () -> m ()
paren s = appendLine "(" >> s >> appendLine ")"

parenIf :: IndentMonad m => Bool -> m () -> m ()
parenIf cond = if cond then paren else id

parenExprI :: IndentMonad m => (Prio -> Bool) -> NExpr -> m ()
parenExprI pred e = parenIf (pred $ exprPrio e) (exprI e)

binaryOpNeedsParen :: Bool -> Prio -> Prio -> Bool
binaryOpNeedsParen isLeftChild opprio childprio =
    opprio < childprio || (
        opprio == childprio &&
        not ((if isLeftChild then id else flip)
            associates childprio opprio)
    )

bindingI :: IndentMonad m => Binding NExpr -> m ()
bindingI b = case b of
    NamedVar path val -> do
        pathI path >> appendLine " = " >> exprI val >> appendLine ";"
    Inherit set vars -> do
        appendLine "inherit "
        maybe noop (\s -> appendLine "(" >> exprI s >> appendLine ") ") set
        intercalateM (appendLine " ") (map keyNameI vars)
        appendLine ";"

listI :: IndentMonad m => [NExpr] -> m ()
listI vals = do
    appendLine "["
    intercalateM (appendLine " ")
                 (map (parenExprI (listPrio <=)) vals)
    appendLine "]"

pathI :: IndentMonad m => NAttrPath NExpr -> m ()
pathI p = intercalateM (appendLine ".") $ map keyNameI p

keyNameI :: IndentMonad m => NKeyName NExpr -> m ()
keyNameI kn = case kn of
    StaticKey k -> appendLine $ T.unpack k
    DynamicKey (Plain s) -> stringI s
    DynamicKey (Antiquoted e) -> do
        appendLine "${"
        exprI e
        appendLine "}"

atomI :: IndentMonad m => NAtom -> m ()
atomI = appendLine . T.unpack . atomText

stringI :: IndentMonad m => NString NExpr -> m ()
stringI s = let t = case s of
                    { DoubleQuoted t -> t; Indented t -> t }
    in tryOneLine (\b ->
        if b then do
            appendLine "\""
            mapM_ escapeAntiquotedI t
            appendLine "\""
        else do
            appendLine "''"
            lastEndedWithNewLine <- indent $ do
                newLine
                foldM
                    (\lastEndedWithNewLine -> \item -> do
                        when lastEndedWithNewLine newLine
                        escapeMultilineI item)
                    False
                    t
            when lastEndedWithNewLine newLine
            appendLine "''")

escapeAntiquotedI :: IndentMonad m => Antiquoted T.Text NExpr -> m ()
escapeAntiquotedI a = case a of
    Plain t -> appendLine $ tail $ init $ show $ T.unpack t
    Antiquoted e -> do
        appendLine "${"
        exprI e
        appendLine "}"

-- returns endsWithNewLine
escapeMultilineI :: IndentMonad m => Antiquoted T.Text NExpr -> m Bool
escapeMultilineI a = case a of
    Plain t -> do
        intercalateM newLine $ map appendLine $ lines $ T.unpack t
        return $ last (T.unpack t) == '\n'
    Antiquoted e -> do
        appendLine "${" >> exprI e >> appendLine "}"
        return False

unaryOpI :: IndentMonad m => NUnaryOp -> NExpr -> m ()
unaryOpI op ex = do
    appendLine $ unOpStr op
    parenExprI (unaryPrio op <) ex


binaryOpI :: IndentMonad m => NBinaryOp -> NExpr -> NExpr -> m ()
binaryOpI op l r = do
    parenExprI (binaryOpNeedsParen True (binaryPrio op)) l
    appendLine $ " " <> binOpStr op <> " "
    parenExprI (binaryOpNeedsParen False (binaryPrio op)) r

selectI :: IndentMonad m => NExpr -> NAttrPath NExpr -> Maybe NExpr -> m ()
selectI set attr def = do
    parenExprI (selectPrio <=) set
    appendLine "."
    pathI attr
    maybe noop
          (\x -> do
            appendLine " or "
            parenExprI (selectPrio <=) x)
          def

hasAttrI :: IndentMonad m => NExpr -> NAttrPath NExpr -> m ()
hasAttrI set attr = do
    parenExprI (hasAttrPrio <=) set
    appendLine " ? "
    pathI attr

absI :: IndentMonad m => Params NExpr -> NExpr -> m ()
absI par ex = paramI par >> appendLine ": " >> exprI ex

paramI :: IndentMonad m => Params NExpr -> m ()
paramI par = case par of
    Param p -> appendLine $ T.unpack p
    ParamSet set name -> do
        paramSetI set
        maybe noop (\n -> appendLine " @ " >> appendLine (T.unpack n)) name

paramSetI :: IndentMonad m => ParamSet NExpr -> m ()
paramSetI set = tryOneLine
    (\oneLine -> do
        let space = if oneLine then appendLine " " else newLine
        appendLine "{"
        indent $ space
        indent $ case set of
            FixedParamSet m -> do
                paramSetContentsI space (M.toList m)
            VariadicParamSet m -> do
                paramSetContentsI space (M.toList m)
                appendLine ","
                space >> appendLine "..."
        space >> appendLine "}")

paramSetContentsI :: IndentMonad m => m () -> [(T.Text, Maybe NExpr)] -> m ()
paramSetContentsI space set =
    intercalateM
        (appendLine "," >> space)
        (map (\(k, x) -> do
            appendLine $ T.unpack k
            maybe noop (\e -> appendLine " ? " >> exprI e) x
         ) set)

appI :: IndentMonad m => NExpr -> NExpr -> m ()
appI f x = do
    parenExprI (appPrio <) f
    appendLine " "
    parenExprI (appPrio <=) x

setI :: IndentMonad m => Bool -> [Binding NExpr] -> m ()
setI rec binds = do
    when rec $ appendLine "rec "
    if binds == [] then appendLine "{}"
    else tryOneLine
        (\oneLine -> do
            let space = if oneLine then appendLine " " else newLine
            appendLine "{"
            indent $ space >> intercalateM space (map bindingI binds)
            space >> appendLine "}")

letI :: IndentMonad m => [Binding NExpr] -> NExpr -> m ()
letI binds ex = tryOneLine
    (\oneLine -> do
        let space = if oneLine then appendLine " " else newLine
        appendLine "let"
        indent $ space >> intercalateM space (map bindingI binds)
        space >> appendLine "in" >> space
        exprI ex)

ifI :: IndentMonad m => NExpr -> NExpr -> NExpr -> m ()
ifI cond then_ else_ = do
    appendLine "if "
    exprI cond
    appendLine " then "
    exprI then_
    appendLine " else "
    exprI else_

stmtI :: IndentMonad m => String -> NExpr -> NExpr -> m ()
stmtI kw it expr = do
    appendLine $ kw ++ " "
    exprI it
    appendLine "; "
    exprI expr
