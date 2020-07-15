# Overview
This demonstrates a bug in Terraform v0.13.0-beta3 that occurs when trying to use a local provider
on Windows. The bug occurs when trying to initialize a Terraform configuration directory that has a
reference to a local provider inside the `required_providers` block. On Windows, `terraform init`
will fail from a console that does not have elevated privileges because it fails to copy the local
provider beneath the `.terraform` directory. More details are provided below.

## Repo Structure
This repository has two parts:

* A basic Terraform configuration directory
* A basic custom Terraform provider

The custom Terraform provider is simply the bare bones needed to compiler the provider and make it
callable from the main Terraform binary.

The Terraform configuration is a basic configuration that declares the custom provider as a required
provider and declares a `provider` block for the custom provider.

## Reproduction Steps
Since this bug impacts Terraform on Windows, it goes without saying that these need to be run on a
Windows system. I tested this on Windows 10 1909. First, download and install v0.13.0-beta3 of
Terraform and install it on your path. I used the windows_amd64 build for this.

Next, from a console that does not have elevated privileges, build the custom Terraform provider by
running the `build.bat` script under the `terraform-provider-example` directory. This will build the
provider and install it under the
`configuration\terraform.d\plugins\example.local\mvromer\example\0.0.1\%GOOS%_%GOARCH%\` directory
with the output file name of `terraform-provider-example_v0.0.1.exe`. This is in accordance with the
new local provider directory structure that goes into effect with 0.13 of Terraform.

> NOTE: For the remainder of this document, I will use `windows_amd64` in place of
> `%GOOS%_%GOARCH%` since that's the environment in which I tested.

Last, change into the `configuration` directory and run `terraform init` from the same console. The
following output should be observed:

```
Initializing the backend...

Initializing provider plugins...
- Finding latest version of example.local/mvromer/example...

- Installing example.local/mvromer/example v0.0.1...
Error: Failed to install provider

Error while installing example.local/mvromer/example v0.0.1: failed to either
symlink or copy
C:\XXXXXX\terraform-windows-local-provider-copy-bug\configuration\terraform.d\plugins\example.local\mvromer\example\0.0.1\windows_amd64
to
C:\XXXXXX\terraform-windows-local-provider-copy-bug\configuration\.terraform\plugins\example.local\mvromer\example\0.0.1\windows_amd64:
open
C:\XXXXXX\terraform-windows-local-provider-copy-bug\configuration\.terraform\plugins\example.local\mvromer\example\0.0.1\windows_amd64\terraform-provider-example_v0.0.1.exe:
The system cannot find the path specified.
```

Lastly, open an elevated console, change back into the `configuration` directory, and run the
`terraform init` command again. The following output should be observed:

```
Initializing the backend...

Initializing provider plugins...
- Finding latest version of example.local/mvromer/example...
- Installing example.local/mvromer/example v0.0.1...
- Installed example.local/mvromer/example v0.0.1 (unauthenticated)

The following providers do not have any version constraints in configuration,
so the latest version was installed.

To prevent automatic upgrades to new major versions that may contain breaking
changes, we recommend adding version constraints in a required_providers block
in your configuration, with the constraint strings suggested below.

* example.local/mvromer/example: version = "~> 0.0.1"

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.
```

## Root Cause
The function in Terraform responsible for configuring the `.terraform` directory with the local
providers is [installFromLocalDir](https://github.com/hashicorp/terraform/blob/v0.13.0-beta3/internal/providercache/package_install.go#L117).
Among other things, this function takes in a parameter of type `PackageMeta` that represents the
provider to install/link into the `.terraform` directory. It also takes a `targetDir` parameter that
represents the destination directory for the installed/linked provider. For the local provider in
this example, the `targetDir` refers to the
`.terraform\plugins\example.local\mvromer\example\0.0.1\windows_amd64` directory.

The `installFromLocalDir` function will first try to symlink the provider to the target directory.
If that fails, then it will do a deep copy. On Windows 10, symlink creation requires elevated
privileges, so the call to `terraform init` from the elevated console results in the file system
item `.terraform\plugins\example.local\mvromer\example\0.0.1\windows_amd64` being a symlink back to
where the local provider is originally sourced from.

Delete the `.terraform` directory and rerun `terraform init` from the **non-elevated** console. Note
the error generated:

```
Error while installing example.local/mvromer/example v0.0.1: failed to either
symlink or copy
C:\XXXXXX\terraform-windows-local-provider-copy-bug\configuration\terraform.d\plugins\example.local\mvromer\example\0.0.1\windows_amd64
to
C:\XXXXXX\terraform-windows-local-provider-copy-bug\configuration\.terraform\plugins\example.local\mvromer\example\0.0.1\windows_amd64:
open
C:\XXXXXX\terraform-windows-local-provider-copy-bug\configuration\.terraform\plugins\example.local\mvromer\example\0.0.1\windows_amd64\terraform-provider-example_v0.0.1.exe:
The system cannot find the path specified.
```

Two things:

1. The error is generated at the
  [end of installFromLocalDir](https://github.com/hashicorp/terraform/blob/v0.13.0-beta3/internal/providercache/package_install.go#L174)
  after the call to [copydir.CopyDir](https://github.com/hashicorp/terraform/blob/v0.13.0-beta3/internal/copydir/copy_dir.go#L35)
  failed.
2. The error specifically says a
  [call to open from within copydir.CopyDir](https://github.com/hashicorp/terraform/blob/v0.13.0-beta3/internal/copydir/copy_dir.go#L97)
  failed because it could not find the specified *destination* path.

Exploring the `.terraform` directory, we can see that `installFromLocalDir` created directories up
to and including `.terraform\plugins\example.local\mvromer\example\0.0.1`. Thus, the reason `open`
failed is because the `windows_amd64` directory in the path
`.terraform\plugins\example.local\mvromer\example\0.0.1\windows_amd64\terraform-provider-example_v0.0.1.exe`
did not exist.

The root issue is that `copydir.CopyDir` is
[called with the `absNew` and `absCurrent` values](https://github.com/hashicorp/terraform/blob/v0.13.0-beta3/internal/providercache/package_install.go#L172),
which are respectively the target and source directories converted to absolute paths. The
documentation for `copydir.CopyDir`
[states that both directories must exist](https://github.com/hashicorp/terraform/blob/v0.13.0-beta3/internal/copydir/copy_dir.go#L13).
We've already seen that this pre-condition isn't met because the `windows_amd64` directory doesn't
exist in the destination path.

The cause of this issue is that `installFromLocalDir` will
[only create the parent directory of the destination folder](https://github.com/hashicorp/terraform/blob/v0.13.0-beta3/internal/providercache/package_install.go#L159), i.e., `.terraform\plugins\example.local\mvromer\example\0.0.1`, with a call to
`os.MkdirAll`, but it doesn't create the destination directory itself.

It should be noted that the call to `os.MkdirAll` *is* correct. The parent of the destination
directory is created so that `installFromLocalDir` can try to symlink the final destination
directory. However, if symlink creation fails and a deep copy is tried instead, then the final
destination directory *needs* to be created prior to the call to `copydir.CopyDir`.

## Proposed Solution
Immediately before the call to `copydir.CopyDir`, the `installFromLocalDir` function should create
the final destination directory represented by the `absNew` value. One possible approach would be to
add the following bit of code prior to the call:

```go
err = os.Mkdir(absNew, 0755)
if err != nil {
    return nil, fmt.Errorf("failed to create target directory %s prior to deep copy: %s", targetDir, err)
}
```
