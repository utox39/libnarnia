# How to contribute to libnarnia

## Did you find a bug?

- Do not open up a GitHub issue if the bug is a security vulnerability, refer to the [security policy](https://github.com/utox39/libnarnia/blob/main/SECURITY.md).
- Ensure the bug was not already reported by searching on GitHub under [Issues](https://github.com/utox39/libnarnia/issues).
- If you're unable to find an open issue addressing the problem, open a new one.

## Do you want to make some changes to the code or documentation?

1. Fork the repo.
2. Create a new branch (because the `main` branch is protected).
3. Make your changes, then run the test suite and the formatter:

   ```sh
   zig build test --summary all
   zig fmt src build.zig
   ```

   If you changed the C bindings in `src/c_api.zig`, keep `include/narnia.h`
   in lockstep with them and run:

   ```sh
   zig build c-test
   ```

4. Commit and push the changes to the new branch.
5. Open a pull request.

---

**Thank you for your contribution!**
