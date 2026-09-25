package com.zoaz.bow;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Set;

import me.zed_0xff.zombie_buddy.Exposer;
import zombie.characters.IsoPlayer;
import zombie.core.skinnedmodel.ModelManager;
import zombie.inventory.InventoryItem;
import zombie.iso.IsoCell;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.SpriteModel;
import zombie.iso.sprite.IsoSprite;
import zombie.scripting.ScriptManager;
import zombie.scripting.objects.ItemTag;

/**
 * The bow engine (Bow API) -- a layer running IN PARALLEL with the vanilla weapon engine. It changes nothing and intercepts nothing.
 *
 * <h2>Design rules (fixed by the author, 2026-09-18)</h2>
 * <ul>
 *   <li><b>Copy vanilla, never replace it</b>: this class only supplies computation; vanilla keeps behaving exactly as before.
 *       Vanilla is not "switched off" -- it simply does not recognise this bow (kept out by the item definition).</li>
 *   <li>The ballistic model borrows the FIELD SEMANTICS of Rust ({@code gravityModifier} / {@code DragCurve} /
 *       {@code stringBonusVelocity} and the like), while the implementation is completely independent.</li>
 *   <li>This class holds <b>no {@code @Patch} at all</b> -- no bytecode patching, so a PZ update cannot make
 *       patch application fail, and there is no IllegalAccessError risk from inlined Advice.</li>
 * </ul>
 *
 * <h2>How Lua calls in</h2>
 * {@code @Exposer.LuaClass(name = "BowAPI.BowAPI")} exposes the class as {@code BowAPI.BowAPI}; it is
 * <b>NOT flattened onto {@code BowAPI}</b>. The evidence comes from a repair mod that demonstrably works:
 * {@code ChevalDeFriseRepair.lua:37} states outright that the correct path is
 * {@code ChevalZB.ChevalRepair.plan(...)} and not {@code ChevalZB.plan(...)}.
 * So the Lua side must write {@code BowAPI.BowAPI.solvePitch(...)}.
 * ({@code BAS_Debug3D.lua} probes both paths, so either layout works there.)
 *
 * <h2>Public API discipline</h2>
 * {@code exposeLikeJavaRecursively} exposes <b>every</b> public member, and any type Kahlua cannot handle
 * aborts the exposure pass and drags other mods down with it. Therefore:
 * <ul>
 *   <li>Public signatures use <b>primitive types and String only</b> (never List/Map/array).</li>
 *   <li>Every number handed to Lua must be a {@code double} (Kahlua accepts Double as a number and nothing else;
 *       an Integer makes the Lua side raise
 *       {@code __le not defined for operand}).</li>
 * </ul>
 *
 * <h2>Scope of phase one</h2>
 * Pure math plus a registry, touching no game object: the aim was to prove the ZombieBuddy-load and Lua-bridge chain first.
 * Entity management (an IsoMovingObject subclass) and per-frame stepping came after the bridge was verified.
 */
@Exposer.LuaClass(name = "BowAPI.BowAPI")
public final class BowAPI {

    /** Bridge probe. Lua must test for the actual METHOD (BowAPI.version); testing for the table alone gives a false positive. */
    public static final String VERSION = "0.1.0";

    /**
     * Per-bow parameters. What each index means is in {@link #IDX_SPEED}.
     * Internal field, not exposed to Lua.
     */
    private static final HashMap<String, double[]> BOWS = new HashMap<>();

    public static final int IDX_SPEED = 0;
    public static final int IDX_GRAVITY = 1;
    public static final int IDX_DRAG = 2;
    public static final int IDX_MAX_RANGE = 3;
    public static final int IDX_DMG_MIN = 4;
    public static final int IDX_DMG_MAX = 5;
    public static final int IDX_CRIT_CHANCE = 6;
    private static final int LEN = 7;

    private BowAPI() {
    }

    /** Bridge probe: if Lua calls {@code BowAPI.version()} and gets a non-empty string, the jar loaded and the bridge is up. */
    public static String version() {
        return VERSION;
    }

    /**
     * Register a bow. Any mod may register its own bow -- this is the extension point of the "bow API".
     *
     * @param fullType   of the form {@code BAS.BAS_Bow}
     * @param speed      launch speed (tiles per frame)
     * @param gravity    gravitational acceleration (tiles per frame^2)
     * @param drag       linear drag coefficient (0 = ideal parabola; Rust's DragCurve, linear to start with)
     * @param maxRange   maximum range (tiles)
     * @param dmgMin     minimum damage
     * @param dmgMax     maximum damage
     * @param critChance critical chance (0..100)
     */
    public static boolean registerBow(String fullType, double speed, double gravity,
                                      double drag, double maxRange,
                                      double dmgMin, double dmgMax, double critChance) {
        if (fullType == null || fullType.isEmpty()) {
            return false;
        }
        double[] p = new double[LEN];
        p[IDX_SPEED] = speed;
        p[IDX_GRAVITY] = gravity;
        p[IDX_DRAG] = drag;
        p[IDX_MAX_RANGE] = maxRange;
        p[IDX_DMG_MIN] = dmgMin;
        p[IDX_DMG_MAX] = dmgMax;
        p[IDX_CRIT_CHANCE] = critChance;
        BOWS.put(fullType, p);
        return true;
    }

    /** Whether this fullType has been registered as a bow. */
    public static boolean isBow(String fullType) {
        return fullType != null && BOWS.containsKey(fullType);
    }

    /** The tag name written in the script ({@code Tags = BowEngine}). */
    private static final String BOW_TAG_NAME = "BowEngine";

    /**
     * Claimed by <b>item tag</b>: any mod whose item script says {@code Tags = BowEngine} belongs to the bow
     * engine -- no registration and no Lua edit needed.
     *
     * <p>This mirrors vanilla's {@code IsAimedFirearm} (write it and the gun engine takes over); here
     * <b>declaring the tag is what takes over</b>.
     *
     * <p>CAUTION: {@code ItemTag} objects cannot be compared by identity, and {@code toString()} must not be
     * expected to equal the name written in the script -- {@code ItemTag.toString()} returns
     * {@code Registries.ITEM_TAG.getLocation(this).toString()}, the namespaced all-lowercase form
     * ({@code base:bowengine}). On top of that {@code ItemTag.register()} allocates a {@code new ItemTag(id)}
     * every time, so the registry value can be replaced and a cached object goes stale.
     * So this walks the live tag set on every call and compares the path part only -- the most robust option.
     *
     * @param item the game item (passed as Object and type-checked here; no Java collection in a public signature)
     */
    public static boolean hasBowTag(Object item) {
        if (!(item instanceof InventoryItem)) {
            return false;
        }
        Set<ItemTag> tags = ((InventoryItem) item).getTags();
        if (tags == null || tags.isEmpty()) {
            return false;
        }
        for (ItemTag t : tags) {
            if (t == null) {
                continue;
            }
            String s = t.toString();
            if (s == null) {
                continue;
            }
            int i = s.indexOf(':');
            String path = (i >= 0) ? s.substring(i + 1) : s;
            if (BOW_TAG_NAME.equalsIgnoreCase(path)) {
                return true;
            }
        }
        return false;
    }

    /** Number of registered bows (debugging). */
    public static double bowCount() {
        return (double) BOWS.size();
    }

    /**
     * Read one parameter; an unregistered bow returns {@code defaultValue}.
     *
     * @param which see {@link #IDX_SPEED} and the other index constants
     */
    public static double getParam(String fullType, double which, double defaultValue) {
        double[] p = BOWS.get(fullType);
        if (p == null) {
            return defaultValue;
        }
        int i = (int) which;
        if (i < 0 || i >= p.length) {
            return defaultValue;
        }
        return p[i];
    }

    /**
     * Closed-form ballistic solution: the elevation needed to reach horizontal distance d at height difference dz.
     *
     * <p>Identical to the formula currently used by {@code BAS_Projectile.getAim} (the flat/low solution):
     * <pre>
     *   v2    = v*v
     *   inner = v2*v2 - g*(g*d*d + 2*dz*v2)
     *   pitch = atan((v2 - sqrt(inner)) / (g*d))
     * </pre>
     * Note that the closed form holds <b>under pure gravity only</b>. With drag (drag &gt; 0) it drifts, and
     * the arrow lands short of the cursor, further off the longer the shot. Pinning the landing point to the
     * cursor needs numeric iteration -- later work (see {@link #solvePitchIterative}).
     *
     * @param d  horizontal distance (tiles), measured from the launch point
     * @param dz target height minus launch height (tiles); positive = the target is higher
     * @return elevation in radians; 45 degrees (pi/4) when no solution exists
     */
    public static double solvePitch(double d, double dz, double v, double g) {
        if (d <= 1.0) {
            return Math.PI / 4.0;
        }
        double v2 = v * v;
        double inner = v2 * v2 - g * (g * d * d + 2.0 * dz * v2);
        if (inner < 0.0) {
            return Math.PI / 4.0;
        }
        double den = g * d;
        if (den <= 0.0) {
            return Math.PI / 4.0;
        }
        return Math.atan((v2 - Math.sqrt(inner)) / den);
    }

    /**
     * Numeric (iterative) version of the ballistic solve, used when drag is enabled.
     *
     * <p>Approach: bisect on the elevation, simulate the flight back down to the target height, compare horizontal distance.
     * Slower than the closed form, but still accurate with drag &gt; 0.
     *
     * @param drag linear drag coefficient; at 0 the result matches {@link #solvePitch}
     * @return elevation in radians
     */
    public static double solvePitchIterative(double d, double dz, double v, double g, double drag,
                                             double dt, int maxSteps) {
        double lo = -Math.PI / 2.0 + 0.001;
        double hi = Math.PI / 2.0 - 0.001;
        for (int iter = 0; iter < 40; iter++) {
            double mid = (lo + hi) * 0.5;
            double vx = v * Math.cos(mid);
            double vy = v * Math.sin(mid);
            double x = 0.0;
            double y = 0.0;
            for (int s = 0; s < maxSteps; s++) {
                // semi-implicit Euler with linear drag
                vy -= g * dt;
                double k = 1.0 - drag * dt;
                if (k < 0.0) {
                    k = 0.0;
                }
                vx *= k;
                vy *= k;
                x += vx * dt;
                y += vy * dt;
                if (x >= d) {
                    break;
                }
            }
            if (y < dz) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return (lo + hi) * 0.5;
    }

    /**
     * Velocity after one integration step (drag included). Linear drag: v *= (1 - drag*dt).
     * Borrows the semantics of Rust's {@code DragCurve}; linear approximation now, a curve later if it helps.
     */
    public static double applyDrag(double v, double drag, double dt) {
        double k = 1.0 - drag * dt;
        if (k < 0.0) {
            k = 0.0;
        }
        return v * k;
    }

    /**
     * The charge bonus applied to launch speed -- Rust's {@code stringBonusVelocity}.
     * Rust's charge moves damage, range and launch speed together; this supplies the launch-speed term.
     *
     * @param charge 0..1 (0 = just started, 1 = fully drawn)
     * @param bonus  the multiplier at full draw (0.3 = full-draw speed x1.3)
     */
    public static double chargedSpeed(double baseSpeed, double charge, double bonus) {
        if (charge < 0.0) {
            charge = 0.0;
        } else if (charge > 1.0) {
            charge = 1.0;
        }
        return baseSpeed * (1.0 + bonus * charge);
    }

    /**
     * Damage falloff with distance -- Rust's {@code DragDamageCurve}.
     * Linear falloff: at maximum range the damage retains {@code minScale}.
     */
    public static double damageAtDistance(double dmg, double dist, double maxRange, double minScale) {
        if (maxRange <= 0.0) {
            return dmg;
        }
        double t = dist / maxRange;
        if (t < 0.0) {
            t = 0.0;
        } else if (t > 1.0) {
            t = 1.0;
        }
        double scale = 1.0 + (minScale - 1.0) * t;
        return dmg * scale;
    }

    // ========================================================================
    // TEMPORARY EXPERIMENT AREA: is a 3D model feasible? (delete once answered)
    //
    // Three questions to answer:
    //   1. Can a custom IsoObject subclass render a 3D model?
    //   2. Does changing spriteModel.rotate every frame actually turn it?
    //   3. Does overriding getSpriteModel() to return a PRIVATE COPY isolate the shared state?
    //
    // Decompiled facts already verified (compendium BAS14):
    //   - IsoObject.renderModel() goes through this.getSpriteModel()  -> overridable
    //   - the precondition !PerformanceSettings.fboRenderChunk returns false at once
    //   - IsoObject.java:6248 reads this.sprite.getProperties() -> sprite must not be null
    //   - ScriptManager.getSpriteModel(name) returns a SHARED script object -> it must be cloned
    // ========================================================================

    private static final ArrayList<Object> TEST_OBJECTS = new ArrayList<Object>();
    private static float testSpin = 0.0f;

    /** Template: the arrow SpriteModel (each arrow clones its own so it can rotate independently). */
    private static SpriteModel arrowModelTemplate;

    /** Build one arrow SpriteModel template -- modelScriptName points at BAS_Arrow in models_arrow.txt. */
    private static SpriteModel getArrowModelTemplate() {
        if (arrowModelTemplate == null) {
            SpriteModel sm = new SpriteModel();
            sm.modelScriptName = "Base.BAS_Arrow";
            sm.scale = 1.0f;
            arrowModelTemplate = sm;
        }
        return arrowModelTemplate;
    }

    /**
     * Base class of every test entity.
     * Common trait: getSpriteModel() is overridden to return THIS instance's own SpriteModel copy.
     * Without that, changing rotate turns every object on the map that uses the same model
     * (ScriptManager hands out the shared script object).
     */
    private abstract static class SpinnableModelObject extends IsoObject {

        SpinnableModelObject(IsoCell cell, IsoGridSquare square, IsoSprite sprite) {
            super(cell, square, sprite);
        }

        abstract void spin(float deg);

        static void applySpin(SpriteModel m, float deg) {
            if (m != null && m.rotate != null) {
                // +X is the arrow's forward direction (confirmed by the author 2026-09-19), so rotating about Y
                // is enough to steer the model on the horizontal plane
                m.rotate.set(0.0f, deg, 0.0f);
            }
        }
    }

    /** Borrow the sprite of a nearby object that carries its OWN model, and clone that model in order to rotate it. */
    private static final class TestModelObject extends SpinnableModelObject {

        private SpriteModel ownModel;

        TestModelObject(IsoCell cell, IsoGridSquare square, IsoSprite sprite) {
            super(cell, square, sprite);
        }

        @Override
        public SpriteModel getSpriteModel() {
            if (this.ownModel == null) {
                SpriteModel shared = super.getSpriteModel();
                if (shared == null) {
                    return null;
                }
                this.ownModel = new SpriteModel();
                this.ownModel.set(shared);
            }
            return this.ownModel;
        }

        @Override
        void spin(float deg) {
            applySpin(this.getSpriteModel(), deg);
        }
    }

    /** Use the mod's own BAS_Arrow model (models_arrow.txt + models_x/weapons/BAS_Arrow.fbx). */
    private static final class ArrowModelObject extends SpinnableModelObject {

        private SpriteModel ownModel;

        ArrowModelObject(IsoCell cell, IsoGridSquare square, IsoSprite sprite) {
            super(cell, square, sprite);
        }

        @Override
        public SpriteModel getSpriteModel() {
            if (this.ownModel == null) {
                this.ownModel = new SpriteModel();
                this.ownModel.set(getArrowModelTemplate());
            }
            return this.ownModel;
        }

        @Override
        void spin(float deg) {
            applySpin(this.getSpriteModel(), deg);
        }
    }

    /** List the SpriteModels registered in ScriptManager (to see the naming format and what is available). */
    public static String zbListSpriteModels() {
        try {
            ArrayList<SpriteModel> all = ScriptManager.instance.getAllSpriteModels();
            StringBuilder sb = new StringBuilder("count=");
            sb.append(all.size()).append(" | ");
            int n = Math.min(all.size(), 20);
            for (int i = 0; i < n; i++) {
                SpriteModel m = all.get(i);
                sb.append(m.getScriptObjectName());
                sb.append("[script=").append(m.modelScriptName).append("] ");
            }
            return sb.toString();
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    /** Find a sprite of a nearby object that carries its OWN model -- use it as a template instead of guessing model names. */
    private static IsoSprite zbFindModelSprite(IsoPlayer pl) {
        IsoCell cell = IsoWorld.instance.getCell();
        int px = (int) Math.floor(pl.getX());
        int py = (int) Math.floor(pl.getY());
        int pz = (int) Math.floor(pl.getZ());
        for (int r = 0; r <= 4; r++) {
            for (int dx = -r; dx <= r; dx++) {
                for (int dy = -r; dy <= r; dy++) {
                    IsoGridSquare s = cell.getGridSquare(px + dx, py + dy, pz);
                    if (s == null) {
                        continue;
                    }
                    java.util.List<IsoObject> objs = s.getObjects();
                    for (int i = 0; i < objs.size(); i++) {
                        IsoObject raw = objs.get(i);
                        if (raw == null) {
                            continue;
                        }
                        IsoSprite sp = raw.getSprite();
                        if (sp != null && sp.spriteModel != null) {
                            return sp;
                        }
                    }
                }
            }
        }
        return null;
    }

    /** Spawn a test object with a model one tile diagonally in front of the player. Returns a readable result string. */
    public static String zbSpawnTestModel(double dist) {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            if (pl == null) {
                return "no player";
            }
            IsoSprite sp = zbFindModelSprite(pl);
            if (sp == null) {
                return "no sprite with a model found within 4 tiles";
            }
            float tx = pl.getX() + (float) dist;
            float ty = pl.getY() + (float) dist;
            float tz = pl.getZ();
            IsoCell cell = IsoWorld.instance.getCell();
            IsoGridSquare sq = cell.getGridSquare(tx, ty, tz);
            if (sq == null) {
                return "no square at " + tx + "," + ty + "," + tz;
            }
            TestModelObject obj = new TestModelObject(cell, sq, sp);
            obj.setSquare(sq);
            sq.getObjects().add(obj);
            sq.invalidateRenderChunkLevel(68L);
            TEST_OBJECTS.add(obj);
            return "OK at " + sq.getX() + "," + sq.getY() + "," + sq.getZ()
                    + " sprite=" + sp.getName()
                    + " model=" + sp.spriteModel.getScriptObjectName();
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    /**
     * Find ANY usable sprite as a carrier. IsoObject.renderModel() reads
     * this.sprite.getProperties(), so sprite must not be null -- but its model is replaced wholesale by
     * ArrowModelObject, so anything will do.
     */
    private static IsoSprite zbFindAnySprite(IsoPlayer pl) {
        IsoCell cell = IsoWorld.instance.getCell();
        int px = (int) Math.floor(pl.getX());
        int py = (int) Math.floor(pl.getY());
        int pz = (int) Math.floor(pl.getZ());
        for (int r = 0; r <= 4; r++) {
            for (int dx = -r; dx <= r; dx++) {
                for (int dy = -r; dy <= r; dy++) {
                    IsoGridSquare s = cell.getGridSquare(px + dx, py + dy, pz);
                    if (s == null) {
                        continue;
                    }
                    java.util.List<IsoObject> objs = s.getObjects();
                    for (int i = 0; i < objs.size(); i++) {
                        IsoObject o = objs.get(i);
                        if (o != null && o.getSprite() != null) {
                            return o.getSprite();
                        }
                    }
                }
            }
        }
        return null;
    }

    /** Diagnostics: under what name the BAS_Arrow model script is registered, and what its mesh/tex resolve to. */
    public static String zbProbeArrowModel() {
        StringBuilder sb = new StringBuilder();
        String[] names = {"Base.BAS_Arrow", "BAS_Arrow", "BAS.BAS_Arrow"};
        for (int i = 0; i < names.length; i++) {
            try {
                Object ms = ScriptManager.instance.getModelScript(names[i]);
                sb.append(names[i]).append("=").append(ms != null ? "FOUND" : "null").append("; ");
            } catch (Throwable t) {
                sb.append(names[i]).append("=EX ").append(t).append("; ");
            }
        }
        try {
            zombie.scripting.objects.ModelScript ms =
                    ScriptManager.instance.getModelScript("Base.BAS_Arrow");
            if (ms == null) {
                ms = ScriptManager.instance.getModelScript("BAS_Arrow");
            }
            if (ms != null) {
                sb.append("| mesh=").append(ms.getMeshName());
                sb.append(" tex=").append(ms.getTextureName());
                sb.append(" static=").append(ms.isStatic);
            }
        } catch (Throwable t) {
            sb.append("| meta EX ").append(t);
        }
        return sb.toString();
    }

    /** Spawn a test entity with the mod's own BAS_Arrow model (models_arrow.txt). */
    public static String zbSpawnArrowModel(double dist) {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            if (pl == null) {
                return "no player";
            }
            IsoSprite sp = zbFindAnySprite(pl);
            if (sp == null) {
                return "no carrier sprite found within 4 tiles";
            }
            float tx = pl.getX() + (float) dist;
            float ty = pl.getY() + (float) dist;
            float tz = pl.getZ();
            IsoCell cell = IsoWorld.instance.getCell();
            IsoGridSquare sq = cell.getGridSquare(tx, ty, tz);
            if (sq == null) {
                return "no square at " + tx + "," + ty + "," + tz;
            }
            ArrowModelObject obj = new ArrowModelObject(cell, sq, sp);
            obj.setSquare(sq);
            sq.getObjects().add(obj);
            sq.invalidateRenderChunkLevel(68L);
            TEST_OBJECTS.add(obj);
            return "OK arrow at " + sq.getX() + "," + sq.getY() + "," + sq.getZ()
                    + " modelScript=Base.BAS_Arrow carrier=" + sp.getName();
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    /** Rotate every test object to the given angle about Y (called by Lua every frame). */
    public static void zbSpinTestModels(double deg) {
        testSpin = (float) deg;
        for (int i = 0; i < TEST_OBJECTS.size(); i++) {
            Object raw = TEST_OBJECTS.get(i);
            if (raw instanceof SpinnableModelObject) {
                ((SpinnableModelObject) raw).spin(testSpin);
            }
        }
    }

    /** Number of test objects currently alive (used to confirm the Lua -> Java call chain). */
    public static double zbTestCount() {
        return TEST_OBJECTS.size();
    }

    /** Delete every test object. */
    public static void zbClearTestModels() {
        for (int i = 0; i < TEST_OBJECTS.size(); i++) {
            Object raw = TEST_OBJECTS.get(i);
            if (!(raw instanceof IsoObject)) {
                continue;
            }
            IsoObject o = (IsoObject) raw;
            try {
                o.removeFromWorld();
                o.removeFromSquare();
            } catch (Throwable t) {
                // best effort
            }
        }
        TEST_OBJECTS.clear();
    }

    // =======================================================================
    // Bone probe (2026-09-21) -- first step of wiring the bow animation; diagnostics only, changes no state.
    //
    // Why this has to be done on the Java side: player:getAnimationPlayer() from Lua hands back an opaque
    // userdata (LuaManager registers no AnimationPlayer method with Lua), so a call such as
    // ap:hasSkinningData() raises "attempted index of non-table".
    // Measured evidence: `[BONE] hasSkinningData() NOT CALLABLE from Lua ... RuntimeException`.
    //
    // The question it answers: are the bow's grip bones `shou` / `shou2` really in the PLAYER'S RUNTIME
    // skeleton table? Every bone lookup in the engine is by name (AnimationPlayer.getSkinningBoneIndex(name, -1));
    // a miss fails silently: attachments do not apply, the animation skips that bone, and nothing is logged.
    // The return type can only be String (ZombieBuddy's exposure limit for Lua: no List/Map).
    // =======================================================================

    /** Dump the player's runtime skeleton table as one String (boneName#index(parentIndex), sorted by index). */
    public static String zbDumpBones() {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            if (pl == null) {
                return "no player instance";
            }
            if (!pl.hasAnimationPlayer()) {
                return "player has no animation player";
            }
            zombie.core.skinnedmodel.animation.AnimationPlayer ap = pl.getAnimationPlayer();
            if (ap == null) {
                return "animation player null";
            }
            if (!ap.hasSkinningData()) {
                return "no skinning data";
            }
            HashMap<String, Integer> idx = ap.getSkinningBoneIndices();
            if (idx == null) {
                return "bone index map null";
            }
            int n = ap.getNumBones();
            // reverse lookup: index -> name, emitted in ascending index order for easy comparison with vanilla's 46-bone list
            String[] names = new String[n];
            for (HashMap.Entry<String, Integer> e : idx.entrySet()) {
                Integer v = e.getValue();
                if (v != null && v.intValue() >= 0 && v.intValue() < n) {
                    names[v.intValue()] = e.getKey();
                }
            }
            StringBuilder sb = new StringBuilder();
            sb.append("BONES num=").append(n).append(" map=").append(idx.size());
            for (int i = 0; i < n; i++) {
                sb.append(" | ").append(i).append(':').append(names[i] == null ? "?" : names[i]);
            }
            // the key question: are those two custom bones present in the table (-1 = absent)
            sb.append(" || shou=").append(ap.getSkinningBoneIndex("shou", -1));
            sb.append(" shou2=").append(ap.getSkinningBoneIndex("shou2", -1));
            sb.append(" L_Finger1=").append(ap.getSkinningBoneIndex("Bip01_L_Finger1", -1));
            sb.append(" R_Finger1=").append(ap.getSkinningBoneIndex("Bip01_R_Finger1", -1));
            sb.append(" Prop1=").append(ap.getSkinningBoneIndex("Bip01_Prop1", -1));
            sb.append(" Prop2=").append(ap.getSkinningBoneIndex("Bip01_Prop2", -1));
            return sb.toString();
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    // =======================================================================
    // Bow skeleton wiring, phase 1 probe (2026-09-21)
    //
    // This section answers one question only: does the engine accept this "bow with bones", and how far.
    // Every judgement below comes from decompiled source rather than guesswork:
    //
    //   · IsoObjectModelDrawer.initMatrixPalette():317
    //       model.tag (SkinningData) is null -> the palette is abandoned outright, so the string can never deform.
    //   - same file :322  an ordinary object (not registered in IsoObjectAnimations) takes exactly this path:
    //       a pre-baked skinning matrix looked up by (model, animationName, animationTime).
    //   - a name mismatch fails silently: animationName must be a key that really exists in
    //       SkinningData.animationClips, or AnimationPlayer.play() returns null and the palette stays uninitialised.
    //   - ModelManager:1536  the clip name comes FROM THE MESH FILE ITSELF:
    //       the animationsMesh must declare keepMeshAnimations for PZ to register
    //       mesh.meshAnimationClips into skinningData.animationClips.
    //
    // So the whole chain is dumped at once -- script resolution -> model load -> skinning -> bone index -> clip name --
    // with every name printed, to avoid the "I assumed it was called A, it is really called B" kind of waste.
    // The return type must be String (ZombieBuddy's exposure limit for Lua: no List/Map).
    // =======================================================================

    // =======================================================================
    // The bow's rendered model: per-frame static models (BAS_BowFrame01..08 in models_bowframes.txt)
    //
    // The one frame-number convention (both ends fixed; see BOW_FRAME_FIRST / BOW_FRAME_LAST):
    //     first frame = 1 = string not drawn (this is what items_bow.txt's StaticModel points at)
    //     last  frame = 8 = fully drawn (charge fraction 1.0)
    // On disk: source frames 1.fbx .. 8.fbx -> installed as BAS_BowFrame01.fbx ..
    // BAS_BowFrame08.fbx (md5 identical) -> script model BAS_BowFrame01 .. 08
    // -> this class builds the modelScript name Base.BAS_BowFrameNN. A break anywhere in that chain shows up as
    // "a full draw still renders frame 1". Validators: Tool\bow_frame_wiring_check.py, Tool\frame_index_mapping_check.py.
    //
    // Why clip scrubbing was dropped: scrubbing can only translate the whole string (it has a single bone),
    // whereas a per-frame static model has the shape the artist posed. Swapping the model means swapping one
    // string, spriteModel.modelScriptName (IsoObjectModelDrawer looks the ModelScript up by it every frame);
    // with static=true the engine releases the palette outright, so no skeleton / skinning / clip or
    //
    // unbounded palette cache is involved. Side effect: meshClips / CLIPS come out empty in zbProbeRig()
    // -- expected, since a static model has no clip. BAS_BowAnim (the clip version) is still in models_bowanim.txt;
    // point BOW_RIG_MODEL back at it whenever a comparison is wanted.
    // =======================================================================

    /** Number of frames of the per-frame static bow (= models in models_bowframes.txt = fbx files on disk). */
    private static final int BOW_FRAME_COUNT = 8;

    /** First frame (always 1): string not drawn -- what items_bow.txt's StaticModel points at. */
    private static final int BOW_FRAME_FIRST = 1;

    /** Last frame (always 8): fully drawn, charge fraction == 1.0. */
    private static final int BOW_FRAME_LAST = BOW_FRAME_COUNT;

    /**
     * Total number of frames (= last frame index, 8). Lua reads this before mapping charge -> frame,
     * so the "8" lives in exactly one place (BOW_FRAME_COUNT here) and Lua and Java cannot drift apart.
     */
    public static double zbBowFrameCount() {
        return (double) BOW_FRAME_COUNT;
    }

    /** Script-name prefix of the per-frame static bow (two digits follow: 01..08). */
    private static final String BOW_FRAME_PREFIX = "Base.BAS_BowFrame";

    /** Script name of frame idx (idx starts at 1; out-of-range values are clamped into 1..8). */
    private static String bowFrameModel(int idx) {
        if (idx < BOW_FRAME_FIRST) {
            idx = BOW_FRAME_FIRST;
        }
        if (idx > BOW_FRAME_LAST) {
            idx = BOW_FRAME_LAST;
        }
        return BOW_FRAME_PREFIX + (idx < 10 ? "0" + idx : "" + idx);
    }

    /** Script name of the model bound to the bow -- currently frame 1 (string not drawn). */
    private static final String BOW_RIG_MODEL = BOW_FRAME_PREFIX + "01";

    private static int boneIdxOf(HashMap<String, Integer> idx, String name) {
        if (idx == null) {
            return -1;
        }
        Integer v = idx.get(name);
        return v == null ? -1 : v.intValue();
    }

    /** Diagnostics: the state of every link in the bow-binding chain. Call from Lua in a loop until it stops saying NOT LOADED. */
    public static String zbProbeRig() {
        StringBuilder sb = new StringBuilder();
        try {
            zombie.scripting.objects.ModelScript ms = ScriptManager.instance.getModelScript(BOW_RIG_MODEL);
            if (ms == null) {
                return "no model script " + BOW_RIG_MODEL;
            }
            String meshName = ms.getMeshName();
            String texName = ms.getTextureName();
            String shaderName = ms.getShaderName();
            boolean bStatic = ms.isStatic;
            sb.append("script mesh=").append(meshName)
              .append(" tex=").append(texName)
              .append(" shader=").append(shaderName)
              .append(" static=").append(bStatic)
              .append(" animationsMesh=").append(ms.animationsMesh);

            zombie.core.skinnedmodel.model.Model m = ModelManager.instance
                    .tryGetLoadedModel(meshName, texName, bStatic, shaderName, true);
            if (m == null && !bStatic && ms.animationsMesh != null) {
                zombie.scripting.objects.AnimationsMesh am =
                        ScriptManager.instance.getAnimationsMesh(ms.animationsMesh);
                if (am == null) {
                    sb.append(" | animationsMesh NOT IN SCRIPTS");
                } else {
                    sb.append(" | amMesh=").append(am.modelMesh == null ? "null" : "ok")
                      .append(" keepAnims=").append(am.keepMeshAnimations);
                    if (am.modelMesh != null) {
                        m = ModelManager.instance.loadModel(meshName, texName, am.modelMesh, shaderName);
                    }
                }
            }
            if (m == null) {
                return sb.append(" | model NOT LOADED YET").toString();
            }
            sb.append(" | ready=").append(m.isReady())
              .append(" mesh=").append(m.mesh == null ? "null" : (m.mesh.isReady() ? "ready" : "loading"));
            if (m.mesh != null && m.mesh.meshAnimationClips != null) {
                sb.append(" | meshClips(").append(m.mesh.meshAnimationClips.size()).append(")=")
                  .append(m.mesh.meshAnimationClips.keySet());
            }
            zombie.core.skinnedmodel.model.SkinningData sd =
                    (zombie.core.skinnedmodel.model.SkinningData) m.tag;
            if (sd == null) {
                return sb.append(" | SKINNING=NULL <-- palette branch never entered, string cannot deform").toString();
            }
            HashMap<String, Integer> idx = sd.boneIndices;
            sb.append(" | SKINNING=OK bones=").append(idx == null ? -1 : idx.size());
            sb.append(" gongxuan=").append(boneIdxOf(idx, "gongxuan"));
            sb.append(" gong005=").append(boneIdxOf(idx, "gong005"));
            sb.append(" gong012=").append(boneIdxOf(idx, "gong012"));
            sb.append(" bow_root=").append(boneIdxOf(idx, "bow_root"));
            if (sd.animationClips == null) {
                sb.append(" | CLIPS=NULL");
            } else {
                sb.append(" | CLIPS(").append(sd.animationClips.size()).append(")=")
                  .append(sd.animationClips.keySet());
            }
            return sb.toString();
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    // =====================================================================
    // Bow in hand = ENGINE RENDERING: the item's StaticModel + overridePrimaryHandModel
    // ---------------------------------------------------------------------
    // What model is in hand is decided by the engine at ModelManager:643-646:
    //     if (!StringUtils.isNullOrEmpty(chr.overridePrimaryHandModel)) {
    //         overrideHandModels = true;
    //         chr.primaryHandModel = addStatic(slot, chr.overridePrimaryHandModel, "Bip01_Prop1");
    //     }
    // -> write that one string and the engine mounts the STATIC model on Bip01_Prop1 (right hand = bow hand);
    //    position, orientation and following the hand are all the engine's job -- the mod writes no rendering code.
    // Refresh: IsoGameCharacter.resetEquippedHandsModels() (public; internally just
    //       ModelManager.ResetEquippedNextFrame -- vanilla's FishingManager refreshes the same way).
    // "Swapping the model" per frame = pointing that string at another frame's model (only when the frame changes).
    // This mod no longer draws the bow itself: no world object, no SpriteModel, no palette/clip.
    // =====================================================================

    /**
     * Put frame idx in the hand.
     *   1 .. 8 (BOW_FRAME_FIRST .. BOW_FRAME_LAST) = that frame; 1 = not drawn, 8 = fully drawn
     *   idx <= 0 = drop the override and fall back to the item's StaticModel (= frame 1)
     * Out-of-range values are clamped into 1..8 (inside bowFrameModel), so 0.4 / 8.7 / -3 never reach another model.
     */
    public static String zbSetBowHandFrame(double idx) {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            if (pl == null) {
                return "no player";
            }
            int i = (int) Math.round(idx);
            String name;
            if (i <= 0) {
                name = "(clear -> item StaticModel)";
                if (pl.overridePrimaryHandModel == null) {
                    return "already " + name;
                }
                pl.overridePrimaryHandModel = null;
            } else {
                name = bowFrameModel(i);
                if (name.equals(pl.overridePrimaryHandModel)) {
                    return "already " + name;
                }
                pl.overridePrimaryHandModel = name;
            }
            pl.resetEquippedHandsModels();
            return "handModel=" + name + " reset=ok";
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    /** Inspect the current hand model (the override field plus whether the engine has built an instance for it). */
    public static String zbBowHandModel() {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            if (pl == null) {
                return "no player";
            }
            return "override=" + (pl.overridePrimaryHandModel == null ? "null" : pl.overridePrimaryHandModel)
                    + " primaryHandModel=" + (pl.primaryHandModel == null ? "null" : "set");
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    /**
     * Preload the eight frame models -- loading one on first use makes it flash "Loading" at that instant.
     * Call once when the bow is equipped. Returns each frame's load state.
     */
    public static String zbPreloadBowFrames() {
        try {
            StringBuilder sb = new StringBuilder("preload");
            for (int i = 1; i <= BOW_FRAME_COUNT; i++) {
                String name = bowFrameModel(i);
                zombie.scripting.objects.ModelScript ms = ScriptManager.instance.getModelScript(name);
                if (ms == null) {
                    sb.append(" [").append(i).append("=noScript]");
                    continue;
                }
                zombie.core.skinnedmodel.model.Model m = ModelManager.instance.tryGetLoadedModel(ms, true);
                sb.append(" [").append(i).append('=');
                sb.append(m == null ? "null" : (m.isReady() ? "ok" : "loading"));
                sb.append(']');
            }
            return sb.toString();
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    // =====================================================================
    // Probe: turn the bow into an "additional model on the character" (= part of the character model)
    // ---------------------------------------------------------------------
    // In the engine, models that hang off the character and render with the character skeleton (clothes,
    // attached items) are wired like this (ModelManager.newStaticInstance / AnimatedModel.postProcessNewItemInstance):
    //     inst.animPlayer     = the character's player   <- the SAME object is reused, not its own
    //     inst.parentBoneName = a bone name              <- position comes from the character skeleton
    //     body.sub.add(inst)                             <- grafted into the character's model tree
    // Then the render side (AnimatedModel$AnimatedModelInstanceRenderData.initMatrixPalette):
    //     if (!model.isStatic) skinTransforms = inst.animPlayer.getSkinTransforms(model.tag)
    // -> a mesh only has to be "non-static + skinned to the Human skeleton" to deform WITH THE CHARACTER POSE.
    // Placement side, transformToParent: inherit the parent matrix -> take the transform of parentBoneName
    //                          -> optionally multiply by the offset/rotation of the same-named attachment in the model script.
    // Child instances are re-walked every frame (initRenderData rebuilds) -> attach/detach takes effect at once.
    //
    // CAUTION: AnimatedModel.isModelInstanceReady checks child instances one by one: a mesh that is not ready
    //    STOPS THE WHOLE CHARACTER ANIMATION (the engine waits for it). So attach only once the mesh is ready.
    // =====================================================================

    /** Instances attached so far, so they can be detached cleanly. */
    private static final ArrayList<Object> BOW_SUB_INSTANCES = new ArrayList<Object>();

    private static String v3s(org.joml.Vector3f v) {
        return v == null ? "null" : "(" + v.x + "," + v.y + "," + v.z + ")";
    }

    /** Attach a model script to a bone of the character skeleton as a "character child model". */
    private static String attachAsSubModel(String modelName, String boneName) {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            if (pl == null) {
                return "no player";
            }
            zombie.core.skinnedmodel.model.ModelInstance body = pl.getModelInstance();
            zombie.core.skinnedmodel.animation.AnimationPlayer ap = pl.getAnimationPlayer();
            if (body == null || ap == null) {
                return modelName + " -> the character's ModelInstance/AnimationPlayer is null";
            }
            zombie.scripting.objects.ModelScript ms = ScriptManager.instance.getModelScript(modelName);
            if (ms == null) {
                return modelName + " -> no such model script";
            }
            String mesh = ms.getMeshName();
            String tex = ms.getTextureName();
            String sh = ms.getShaderName();
            zombie.core.skinnedmodel.model.Model model =
                    ModelManager.instance.tryGetLoadedModel(mesh, tex, ms.isStatic, sh, true);
            if (model == null && !ms.isStatic && ms.animationsMesh != null) {
                zombie.scripting.objects.AnimationsMesh am =
                        ScriptManager.instance.getAnimationsMesh(ms.animationsMesh);
                if (am != null && am.modelMesh != null) {
                    model = ModelManager.instance.loadModel(mesh, tex, am.modelMesh, sh);
                    if (model == null) {
                        ModelManager.instance.loadAdditionalModel(mesh, tex, false, sh);
                        model = ModelManager.instance.getLoadedModel(mesh, tex, false, sh);
                    }
                }
            }
            if (model == null) {
                return modelName + " -> model not loaded yet (run this probe again in a second)";
            }
            StringBuilder sb = new StringBuilder(modelName);
            sb.append(" static=").append(model.isStatic);
            if (model.tag instanceof zombie.core.skinnedmodel.model.SkinningData) {
                sb.append(" skinning=").append(((zombie.core.skinnedmodel.model.SkinningData) model.tag).numBones()).append(" bones");
            } else {
                sb.append(" skinning=NULL");
            }
            if (model.mesh != null) {
                sb.append(" bbox=").append(v3s(model.mesh.minXyz)).append("~").append(v3s(model.mesh.maxXyz));
            }
            boolean ready = model.mesh != null && model.mesh.isReady() && model.mesh.vb != null;
            sb.append(" meshReady=").append(ready);
            if (!ready) {
                return sb.append(" -> mesh not ready, not attaching (attaching would freeze the character animation)").toString();
            }
            zombie.core.skinnedmodel.model.ModelInstance inst =
                    ModelManager.instance.newInstance(model, pl, ap);
            if (inst == null) {
                return sb.append(" -> newInstance returned null").toString();
            }
            inst.parent = body;
            inst.matrixModel = body;
            inst.animPlayer = ap;                 // reuse the character's player
            inst.parentBoneName = boneName;       // hang it on this bone of the character skeleton
            inst.parentBone = ap.getSkinningBoneIndex(boneName, -1);
            body.sub.add(inst);
            BOW_SUB_INSTANCES.add(inst);
            sb.append(" -> attached to ").append(boneName).append("(idx=").append(inst.parentBone)
              .append(") character sub=").append(body.sub.size());
            return sb.toString();
        } catch (Throwable t) {
            return modelName + " -> EX " + t;
        }
    }

    /**
     * Probe entry point.
     *   mode 0 = inspect only, attach nothing; 1 = attach the current bow (BAS_BowAnim);
     *   2 = attach the old Human-weighted bow (BAS_BowBlend); 3 = attach both.
     * Both attach to Bip01_Prop1 (the engine maps Prop1 -> R_Hand, Prop2 -> L_Hand).
     */
    public static String zbProbeAttachBow(double mode) {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            if (pl == null) {
                return "no player";
            }
            zombie.core.skinnedmodel.animation.AnimationPlayer ap = pl.getAnimationPlayer();
            zombie.core.skinnedmodel.model.ModelInstance body = pl.getModelInstance();
            StringBuilder sb = new StringBuilder();
            sb.append("body=").append(body != null ? "ok" : "NULL");
            sb.append(" animPlayer=").append(ap != null ? "ok" : "NULL");
            if (ap != null) {
                sb.append(" Prop1(idx)=").append(ap.getSkinningBoneIndex("Bip01_Prop1", -1));
                sb.append(" Prop2(idx)=").append(ap.getSkinningBoneIndex("Bip01_Prop2", -1));
            }
            if (body != null) {
                sb.append(" sub=").append(body.sub.size());
            }
            sb.append(" attached=").append(BOW_SUB_INSTANCES.size());
            int m = (int) mode;
            if (m == 0) {
                return sb.toString();
            }
            sb.append("\n  ");
            if (m == 1 || m == 3) {
                sb.append(attachAsSubModel("Base.BAS_BowAnim", "Bip01_Prop1"));
                sb.append("\n  ");
            }
            if (m == 2 || m == 3) {
                sb.append(attachAsSubModel("Base.BAS_BowBlend", "Bip01_Prop1"));
            }
            return sb.toString();
        } catch (Throwable t) {
            return "EX " + t;
        }
    }

    /** Detach every instance this probe attached. */
    public static String zbClearAttachedBow() {
        try {
            IsoPlayer pl = IsoPlayer.getInstance();
            zombie.core.skinnedmodel.model.ModelInstance body = pl == null ? null : pl.getModelInstance();
            int n = 0;
            if (body != null) {
                for (int i = 0; i < BOW_SUB_INSTANCES.size(); i++) {
                    if (body.sub.remove(BOW_SUB_INSTANCES.get(i))) {
                        n++;
                    }
                }
            }
            int had = BOW_SUB_INSTANCES.size();
            BOW_SUB_INSTANCES.clear();
            return "removed=" + n + "/" + had + " character sub=" + (body != null ? body.sub.size() : -1);
        } catch (Throwable t) {
            return "EX " + t;
        }
    }
}
