{-# LANGUAGE CPP #-}
module Language.Haskell.TH.ReifyMany.Internal where

#if !(MIN_VERSION_template_haskell(2,7,0))
import Data.List (foldl')
#endif
import Data.Maybe (catMaybes)
import Language.Haskell.TH
import Language.Haskell.TH.ExpandSyns (expandSyns)
import Safe (headMay, tailMay)

-- | Returns 'True' if the 'Dec' is a 'DataD' or 'NewtypeD'
isDataDec :: Dec -> Bool
isDataDec DataD {} = True
isDataDec NewtypeD {} = True
isDataDec _ = False

-- | Returns 'True' if the 'Dec' is a 'DataD', 'NewtypeD', or
-- 'TySynD'.
isNormalTyCon :: Dec -> Bool
isNormalTyCon DataD {} = True
isNormalTyCon NewtypeD {} = True
isNormalTyCon TySynD {} = True
isNormalTyCon _ = False

-- | For data, newtype, and type declarations, yields a list of the
-- types of the fields.  In the case of a type synonyms, it just
-- returns the body of the type synonym as a singleton list.
decToFieldTypes :: Dec -> [[Type]]
decToFieldTypes (DataD _ _ _ cons _) = map conToFieldTypes cons
decToFieldTypes (NewtypeD _ _ _ con _) = [conToFieldTypes con]
decToFieldTypes (TySynD _ _ ty) = [[ty]]
decToFieldTypes _ = []

-- | Returns the types of the fields of the constructor.
conToFieldTypes :: Con -> [Type]
conToFieldTypes (NormalC _ xs) = map snd xs
conToFieldTypes (RecC _ xs) = map (\(_, _, ty) -> ty) xs
conToFieldTypes (InfixC (_, ty1) _ (_, ty2)) = [ty1, ty2]
conToFieldTypes (ForallC _ _ con) = conToFieldTypes con

-- | Returns the names of all type constructors which aren't involved
-- in constraints.
typeConcreteNames :: Type -> [Name]
typeConcreteNames (ForallT _ _ ty) = typeConcreteNames ty
typeConcreteNames (AppT l r) = typeConcreteNames l ++ typeConcreteNames r
typeConcreteNames (SigT ty _) = typeConcreteNames ty
typeConcreteNames (ConT n) = [n]
typeConcreteNames _ = []

-- | Returns the names of all type constructors used when defining
-- type constructors.
decConcreteNames :: Dec -> [Name]
decConcreteNames = concatMap (concatMap typeConcreteNames) . decToFieldTypes

-- | Datatype to capture the fields of 'InstanceD'.
data TypeclassInstance = TypeclassInstance Cxt Type [Dec]
    deriving Show

-- | Given the 'Name' of a class, yield all of the
-- 'TypeclassInstance's, with synonyms expanded in the 'Type' field.
getInstances :: Name -> Q [TypeclassInstance]
getInstances clz = do
    res <- reify clz
    case res of
        ClassI _ xs -> fmap catMaybes $ mapM convertDec xs
        _ -> fail $ "Error in getInstances: " ++ show clz ++ " isn't a class"
  where
#if MIN_VERSION_template_haskell(2,7,0)
    convertDec (InstanceD ctxt typ decs) = do
        typ' <- expandSyns typ
        return $ Just (TypeclassInstance ctxt typ' decs)
    convertDec _ = return Nothing
#else
    convertDec (ClassInstance _ _ ctxt _ typs) = do
        let typ = foldl' AppT (ConT clz) typs
        typ' <- expandSyns typ
        return $ Just (TypeclassInstance ctxt typ' [])
#endif

-- | Returns the first 'TypeclassInstance' where 'instanceMatches'
-- returns true.
lookupInstance :: [TypeclassInstance] -> Name -> Maybe TypeclassInstance
lookupInstance xs n = headMay $ filter (`instanceMatches` n) xs

-- | Checks if the given name is the head of one of the paramaters of
-- the given 'TypeclassInstance'.
instanceMatches :: TypeclassInstance -> Name -> Bool
instanceMatches (TypeclassInstance _ typ _) n' =
    case tailMay $ map (headMay . unAppsT) $ unAppsT typ  of
        Nothing -> False
        Just xs -> not $ null [() | Just (ConT n) <- xs, n == n']

-- | Breaks a type application like @A b c@ into [A, b, c].
unAppsT :: Type -> [Type]
unAppsT = go []
  where
    go xs (AppT l x) = go (x : xs) l
    go xs ty = ty : xs
