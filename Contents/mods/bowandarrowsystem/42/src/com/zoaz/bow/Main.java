package com.zoaz.bow;

import me.zed_0xff.zombie_buddy.Exposer;

/**
 * Optional entry class for ZombieBuddy.
 *
 * <p>At {@code Phase.MAIN} ZombieBuddy tries to load {@code <javaPkgName>.Main}
 * and reflectively call {@code public static void main(String[])} (see
 * {@code Loader.try_call_main}). It runs <b>before</b> {@code PatchEngine.applyPatches},
 * so this is the right place for a load banner and for registering the Lua exposure.</p>
 */
public final class Main {

    private Main() {
    }

    public static void main(String[] args) {
        System.out.println("[BowAPI] ============================================================");
        System.out.println("[BowAPI] Bow engine Java core loaded, version " + BowAPI.VERSION + ".");
        System.out.println("[BowAPI]   Rule: copy vanilla, never replace it -- no bytecode patches, parallel to the vanilla weapon engine.");
        System.out.println("[BowAPI]   Phase one: pure math (ballistic solve / drag / charged speed / distance falloff) + the bow registry.");
        System.out.println("[BowAPI]   Lua probe: a non-empty BowAPI.BowAPI.version() means the bridge is up.");
        System.out.println("[BowAPI]   Note: the exposed name is BowAPI.BowAPI -- it does NOT flatten onto BowAPI.");
        System.out.println("[BowAPI] ============================================================");

        // Register the Lua exposure explicitly.
        // PatchEngine.collectPatches() already exposes it once through @Exposer.LuaClass
        // (Exposer.exposeAnnotatedClasses); calling it again here is belt and braces:
        // exposeClass is idempotent, so if ZB ever changes its annotation scanning the Lua side still gets the BowAPI table.
        try {
            Exposer.exposeClass(BowAPI.class, "BowAPI.BowAPI");
            System.out.println("[BowAPI] exposeClass(BowAPI) OK");
        } catch (Throwable t) {
            System.out.println("[BowAPI] exposeClass(BowAPI) failed (Lua bridge may be missing): " + t);
        }
    }
}
