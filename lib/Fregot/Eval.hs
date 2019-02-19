{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}
module Fregot.Eval
    ( Environment (..), packages, package

    , Value
    , Document
    , Row, rowValue

    , EvalM
    , runEvalM

    , evalVar
    , evalExpr
    , evalTerm
    ) where

import           Control.Lens               (use, view, (%=), (&), (.~), (^.),
                                             _3)
import           Control.Lens.TH            (makeLenses)
import           Control.Monad.Extended     (foldM, forM, forM_, zipWithM_)
import           Control.Monad.Reader       (MonadReader (..), ask)
import           Control.Monad.State        (MonadState (..))
import qualified Data.DisjointSets          as DJ
import qualified Data.HashMap.Strict        as HMS
import           Data.Maybe                 (isNothing)
import qualified Data.Scientific            as Scientific
import qualified Data.Vector                as V
import           Fregot.Eval.Value
import           Fregot.Interpreter.Package (Package)
import qualified Fregot.Interpreter.Package as Package
import qualified Fregot.PrettyPrint         as PP
import           Fregot.Sugar

newtype Scope = Scope {unScope :: HMS.HashMap Var Value}
    deriving (Monoid, Semigroup)

data Context = Context
    { _unification :: !(DJ.DisjointSets Var ())
    , _scope       :: !Scope
    }

$(makeLenses ''Context)

emptyContext :: Context
emptyContext = Context
    { _unification = DJ.empty
    , _scope       = mempty
    }

data Row a = Row
    { _rowContext :: !Context
    , _rowValue   :: !a
    } deriving (Functor)

$(makeLenses ''Row)

instance PP.Pretty PP.Sem a => PP.Pretty PP.Sem (Row a) where
    pretty (Row _ v) = PP.pretty v

type Document a = [Row a]

--------------------------------------------------------------------------------

data Environment = Environment
    { _packages :: !(HMS.HashMap PackageName Package)
    , _package  :: !Package
    } deriving (Show)

$(makeLenses ''Environment)

newtype EvalM a = EvalM {unBranchM :: Environment -> Context -> [Row a]}
    deriving (Functor)

instance Applicative EvalM where
    pure x = EvalM $ \_ ctx -> [Row ctx x]
    EvalM mf <*> EvalM mx = EvalM $ \rs ctx0 -> do
        row1 <- mf rs ctx0
        row2 <- mx rs (row1 ^. rowContext)
        return $! row2 & rowValue .~ (row1 ^. rowValue) (row2 ^. rowValue)

instance Monad EvalM where
    EvalM mx >>= f = EvalM $ \rs ctx0 -> do
        Row ctx1 x <- mx rs ctx0
        unBranchM (f x) rs ctx1

instance MonadReader Environment EvalM where
    ask = EvalM $ \rs ctx -> pure $! Row ctx rs
    local l (EvalM f) = EvalM $ \rs ctx -> f (l rs) ctx

instance MonadState Context EvalM where
    get     = EvalM $ \_ ctx  -> [Row ctx ctx]
    put ctx = EvalM $ \_ _    -> [Row ctx ()]
    state f = EvalM $ \_ ctx0 -> let (x, ctx1) = f ctx0 in [Row ctx1 x]

runEvalM :: Environment -> EvalM a -> Document a
runEvalM rules0 (EvalM f) = f rules0 emptyContext

branch :: [EvalM a] -> EvalM a
branch options = EvalM $ \rs ctx -> do
    EvalM opt <- options
    opt rs ctx

unbranch :: EvalM a -> EvalM [a]
unbranch (EvalM f) = EvalM $ \rs ctx ->
    let rows = f rs ctx in
    [Row ctx (map (view rowValue) rows)]

cut :: EvalM a
cut = EvalM $ \_ _ -> []

negation :: (a -> Bool) -> EvalM a -> EvalM ()
negation trueish (EvalM f) = EvalM $ \rs ctx ->
    let rows = filter (\(Row _ x) -> trueish x) (f rs ctx) in
    if null rows then [Row ctx ()] else []

withDefault :: EvalM a -> EvalM a -> EvalM a
withDefault (EvalM def) (EvalM f) = EvalM $ \env ctx ->
    case f env ctx of
        [] -> def env emptyContext
        xs -> xs

requireComplete :: Eq a => EvalM a -> EvalM a
requireComplete (EvalM f) = EvalM $ \env ctx ->
    let rows = f env ctx in
    case rows of
        (r : more)
            | all ((== r ^. rowValue) . view rowValue) more -> [r]
            | otherwise -> fail
                -- TODO(jaspervdj): Better error message.
                "requireComplete: inconsistent result for complete rule"
        _          -> rows

-- | Note that 'v' MUST be a root in the DisjointSets.
unsafeBind :: Var -> Value -> EvalM ()
unsafeBind root (FreeV alpha) =
    unification %= view _3 . DJ.union root alpha
unsafeBind v val =
    scope %= Scope . HMS.insert v val . unScope

lookupRule :: [Var] -> EvalM (Maybe Package.CompiledRule)
lookupRule [root] = do
    env0 <- ask
    return $ Package.lookup root (env0 ^. package)
lookupRule _ = fail "todo: lookup rules in other packages"

clearContext :: EvalM a -> EvalM a
clearContext mx = do
    ctx <- get
    put emptyContext
    x  <- mx
    put ctx
    return x

--------------------------------------------------------------------------------

ground :: EvalM Value -> EvalM Value
ground mval = do
    val <- mval
    case val of
        FreeV v   -> fail $ "Unknown variable: " ++ show (PP.pretty v)
        WildcardV -> fail $ "Unknown variable: _"
        _         -> return val

evalExpr :: Expr a -> EvalM Value
evalExpr (TermE _ t) = evalTerm t
evalExpr (UnifyE _ x y) = do
    xv <- evalExpr x
    yv <- evalExpr y
    unify xv yv
    return $ BoolV True
evalExpr (AssignE _ v x) = do
    xv <- evalExpr x
    -- TODO(jaspervdj): Do we need to check that 'v' is indeed free?
    unsafeBind v xv
    return xv
evalExpr (BinOpE _ x o y) = evalBinOp x o y
evalExpr (ParensE _ e) = evalExpr e

evalTerm :: Term a -> EvalM Value
evalTerm (RefT _ _ v args) = do
    mbCompiledRule <- lookupRule [v]
    case args of
        -- Using a rule with an index.  This only triggers if the rule requires
        -- an argument, i.e. it is not a complete rule.
        [RefBrackArg x]
                | Just crule <- mbCompiledRule
                , Package.CompleteRule /= (crule ^. Package.cruleKind) -> do
            y <- evalTerm x
            -- Remember to unify the index back with the argument that was
            -- given.
            (mbIndex, res) <- evalCompiledRule crule (Just y)
            forM_ mbIndex $ unify y
            return res
        _ -> do
            val <- evalVar v
            foldM evalRefArg val args

evalTerm (CallT _ f args)
    -- TODO(jaspervdj): Use a more reliable system to register FFI functions.
    | f == ["count"] = do
        vargs <- mapM evalTerm args
        case vargs of
            [ArrayV a] -> return $ NumberV $ fromIntegral $ V.length a
            _          -> fail $ "Bad parameter for count"
    | otherwise = do
        mbCompiledRule <- lookupRule f
        case mbCompiledRule of
            Just cr -> do
                vargs <- mapM evalTerm args
                (vargs', res) <- evalUserFunction cr vargs
                -- TODO(jaspervdj): We really only need to unify "output
                -- arguments", but we don't have code to detect the output
                -- arguments at this point.
                zipWithM_ unify vargs vargs'
                return res
            Nothing -> fail $ "Not implemented: function call: " ++ show f

evalTerm (VarT _ v)
    | unVar v == "_" = return WildcardV
    | otherwise      = evalVar v
evalTerm (ScalarT _ s) = evalScalar s
evalTerm (ArrayT _ a) = do
    bs <- mapM evalExpr a
    return $ ArrayV $ V.fromList bs
evalTerm (SetT _ s) = do
    bs <- mapM evalExpr s
    return $ SetV $ V.fromList bs
evalTerm (ObjectT _ o) = do
    obj <- forM o $ \(kt, vt) -> do
        key <- evalObjectKey kt
        case key of
            StringV txt -> do
                val <- evalExpr vt
                return (txt, val)
            _ -> fail "Unsupported object key type"
    return $ ObjectV $ HMS.fromList obj

evalTerm (ArrayCompT _ chead cbody) = do
    rows <- unbranch $ evalRuleBody cbody (evalTerm chead)
    return $ ArrayV $ V.fromList rows

evalTerm (SetCompT _ _ _)      = fail "set comprehensions not supported"
evalTerm (ObjectCompT _ _ _ _) = fail "object comprehensions not supported"

evalVar :: Var -> EvalM Value
evalVar v = do
    uni  <- use unification
    scop <- use scope
    let (rv, ()) = DJ.root v uni
    case HMS.lookup rv (unScope scop) of
        Just val -> return val
        Nothing -> do
            mbCompiledRule <- lookupRule [rv]
            case mbCompiledRule of
                Nothing    -> return (FreeV rv)
                Just crule -> do
                    (_mbIndex, res) <- evalCompiledRule crule Nothing
                    return res

-- NOTE (jaspervdj): I suspect these are roughly the cases we want to care
-- about:
--
-- * indexing rules
-- * indexing "cached/precomputed" rules
-- * indexing actual values, i.e. objects and arrays
evalRefArg :: Value -> RefArg a -> EvalM Value
evalRefArg indexee refArg = do
    idx <- evalTerm (getRefArgTerm refArg)
    case idx of
        WildcardV -> case indexee of
            ArrayV a  -> branch [return val | val <- V.toList a]
            SetV s -> branch [return val | val <- V.toList s]
            ObjectV o -> branch [return val | (_, val) <- HMS.toList o]
            _ -> fail $
                "evalRefArg: cannot index " ++ describeValue indexee ++
                " with a free variable"

        FreeV unbound -> case indexee of
            ArrayV a -> branch
                [ unsafeBind unbound (NumberV $ fromIntegral i) >> return val
                | (i, val) <- zip [0 :: Int ..] (V.toList a)
                ]
            SetV s -> branch
                -- | NOTE(jaspervdj): Returning true below is based on the idea
                -- that rules always return true if they don't have a return
                -- value.  We bind the index to the thing in the list so the
                -- user should use that.
                [ unsafeBind unbound val >> return (BoolV True)
                | val <- V.toList s
                ]
            ObjectV o -> branch
                [ unsafeBind unbound (StringV key) >> return val
                | (key, val) <- HMS.toList o
                ]
            _ -> fail $
                "evalRefArg: cannot index " ++ describeValue indexee ++
                " with a free variable"

        StringV txt | ObjectV o <- indexee -> case HMS.lookup txt o of
            Nothing -> fail "evalRefArg: key not found"
            Just f  -> return f

        NumberV n
                | Right i <- Scientific.floatingOrInteger n :: Either Double Int
                , ArrayV a <- indexee ->
            if i >= 0 && i < V.length a then
                return (a V.! i)
            else
                fail "evalRefArg: index out of bounds"

        _ | SetV set <- indexee ->
            -- If the LHS is a set, we just test if the index is in there.
            --
            -- NOTE(jaspervdj): Another implementation would be to loop over
            -- all elements in the set, and try to unify `idx` with those.
            -- However, the opa interpreter doesn't seem to do this.
            if idx `V.elem` set
                then return (BoolV True)
                else cut

        _ -> fail $
            "evalRefArg: cannot index " ++ describeValue indexee ++
            " with a " ++ describeValue idx
  where
    getRefArgTerm (RefBrackArg t)       = t
    getRefArgTerm (RefDotArg a (Var k)) = ScalarT a (String k)

-- | Returns the value of the index value (if given) as well as the result of
-- the rule.
evalCompiledRule
    :: Package.CompiledRule -> Maybe Value
    -> EvalM (Maybe Value, Value)
evalCompiledRule crule mbIndex = case crule ^. Package.cruleKind of
    -- Complete definitions
    Package.CompleteRule -> requireComplete $
        case crule ^. Package.cruleDefault of
            -- If there is a default, then we fill it in if the rule yields no
            -- rows.
            Just def -> withDefault ((,) Nothing <$> evalTerm def) branches
            Nothing  -> branches

    -- TODO(jaspervdj): We currently treat objects and sets the same.  This is
    -- wrong.
    _ ->
        -- If the rule takes an argument, e.g. `resources[id]`, but we refer to
        -- it without argument, e.g. `count(resources)`, we want to evaluate the
        -- document to an array again.
        (if isNothing mbIndex
            then fmap ((,) Nothing . ArrayV . V.fromList . map snd) . unbranch
            else id) $
        branches
  where
    -- Standard branching evaluation of rule definitions.
    branches = branch
        [ evalRuleDefinition def mbIndex
        | def <- crule ^. Package.cruleDefs
        ]

evalUserFunction
    :: Package.CompiledRule -> [Value] -> EvalM ([Value], Value)
evalUserFunction crule _args
    | crule ^. Package.cruleKind /= Package.FunctionRule = fail
        "Non-function called as function"
    | otherwise = fail "todo: evalUserFunction"

evalRuleDefinition
    :: Package.RuleDefinition -> Maybe Value
    -> EvalM (Maybe Value, Value)
evalRuleDefinition ruleDef mbIndex = clearContext $ do
    case (mbIndex, rule ^. ruleHead . ruleIndex) of
        (Nothing, Nothing)   -> evalRuleBody (rule ^. ruleBody) final
        (Just arg, Just tpl) -> do
            tplv <- evalTerm tpl
            unify arg tplv
            evalRuleBody (rule ^. ruleBody) final
        (Just _, Nothing) -> fail $
            "evalRuleDefinition: got argument for rule " ++
            show (PP.pretty (rule ^. ruleHead . ruleName)) ++
            " but didn't expect one"

        -- If the rule definition has an argument, but we didn't give any, we
        -- want to evaluate things anyway.
        (Nothing, Just _) -> evalRuleBody (rule ^. ruleBody) final
  where
    rule  = ruleDef ^. Package.ruleDefRule
    final = do
        res <- case rule ^. ruleHead . ruleValue of
            Nothing   -> return (BoolV True)
            Just term -> evalTerm term

        idx <- traverse evalFree mbIndex
        return (idx, res)

-- | Evaluate the rule body, then perform a continuation.
evalRuleBody :: RuleBody s -> EvalM a -> EvalM a
evalRuleBody lits0 final = go lits0
  where
    go [] = final

    go (lit : lits)
        | lit ^. literalNegation = do
            negation trueish $ ground $ evalExpr $ lit ^. literalExpr
            go lits
        | otherwise = do
            r <- ground $ evalExpr $ lit ^. literalExpr
            if trueish r then go lits else cut

    trueish (BoolV False) = False
    trueish _             = True

evalFree :: Value -> EvalM Value
evalFree (FreeV v) = evalVar v
evalFree val       = return val

evalScalar :: Scalar a -> EvalM Value
evalScalar (String t) = return $ StringV t
evalScalar (Number t) = return $ NumberV t
evalScalar (Bool   b) = return $ BoolV   b
evalScalar Null       = return $ NullV

evalObjectKey :: ObjectKey a -> EvalM Value
evalObjectKey (ScalarK _ s) = evalScalar s
evalObjectKey (VarK _ v)    = evalVar v

evalBinOp :: Expr a -> BinOp -> Expr a -> EvalM Value
evalBinOp x op y = do
    xv <- evalExpr x
    yv <- evalExpr y
    case (xv, op, yv) of
        (_, AssignO, _)   -> return $! BoolV $! xv == yv
        (_, EqualO, _)    -> return $! BoolV $! xv == yv
        (_, NotEqualO, _) -> return $! BoolV $! xv /= yv
        (NumberV xn, LessThanO, NumberV yn) ->
            return $! BoolV $! xn < yn
        (NumberV xn, LessThanOrEqualO, NumberV yn) ->
            return $! BoolV $! xn <= yn
        (NumberV xn, GreaterThanO, NumberV yn) ->
            return $! BoolV $! xn > yn
        (NumberV xn, GreaterThanOrEqualO, NumberV yn) ->
            return $! BoolV $! xn >= yn
        (NumberV xn, PlusO, NumberV yn) ->
            return $! NumberV $! xn + yn
        (NumberV xn, MinusO, NumberV yn) ->
            return $! NumberV $! xn - yn
        (NumberV xn, TimesO, NumberV yn) ->
            return $! NumberV $! xn * yn
        (NumberV xn, DivideO, NumberV yn) ->
            return $! NumberV $! xn / yn
        _ -> fail $
            "evalBinOp: invalid arguments for " ++ show (PP.pretty' op) ++
            ": " ++ describeValue xv ++ ", " ++ describeValue yv

unify :: Value -> Value -> EvalM ()
unify WildcardV _     = return ()
unify _ WildcardV     = return ()
unify (FreeV alpha) v = unsafeBind alpha v
unify v (FreeV alpha) = unsafeBind alpha v
unify lhs rhs         | lhs == rhs = return ()
unify _ _             = cut
