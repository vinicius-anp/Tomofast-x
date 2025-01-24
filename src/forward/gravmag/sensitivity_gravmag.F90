
!========================================================================
!
!                          T o m o f a s t - x
!                        -----------------------
!
!           Authors: Vitaliy Ogarko, Jeremie Giraud, Roland Martin.
!
!               (c) 2021 The University of Western Australia.
!
! The full text of the license is available in file "LICENSE".
!
!========================================================================

!========================================================================================
! A class to calculate sensitivity values for gravity or magnetic field.
!
! Vitaliy Ogarko, UWA, CET, Australia.
!========================================================================================
module sensitivity_gravmag

  use global_typedefs
  use mpi_tools, only: exit_MPI
  use parameters_mag
  use parameters_grav
  use magnetic_field
  use gravity_field
  use grid
  use model
  use data_gravmag
  use sparse_matrix
  use vector
  use wavelet_transform
  use parallel_tools
  use string, only: str
  use sort

  implicit none

  private

  public :: calculate_and_write_sensit
  public :: read_sensitivity_kernel
  public :: read_sensitivity_metadata

  private :: apply_column_weight
  private :: test_grid_cell_order
  private :: get_load_balancing_nelements

  character(len=4) :: SUFFIX(2) = ["grav", "magn"]

contains

!=============================================================================================
! Sanity check for the correct grid cells ordering.
!=============================================================================================
function test_grid_cell_order(par, grid) result(res)
  class(t_parameters_base), intent(in) :: par
  type(t_grid), intent(in) :: grid
  logical :: res

  integer :: t, ind(4)
  integer :: i_res(4), j_res(4), k_res(4)

  ! The very first voxel (expects: 1 1 1)
  ind(1) = 1
  ! The immediate next voxel (expects: 2 1 1)
  ind(2) = 2
  ! The immediate voxel after the X cycles once (expects: 1 2 1)
  ind(3) = par%nx + 1
  !  The immediate voxel after both X and Y cycles once (expects: 1 1 2)
  ind(4) = par%nx * par%ny + 1

  ! Expected results.
  i_res(1) = 1; j_res(1) = 1; k_res(1) = 1 ! 1 1 1
  i_res(2) = 2; j_res(2) = 1; k_res(2) = 1 ! 2 1 1
  i_res(3) = 1; j_res(3) = 2; k_res(3) = 1 ! 1 2 1
  i_res(4) = 1; j_res(4) = 1; k_res(4) = 2 ! 1 1 2

  res = .true.

  do t = 1, 4
    ! Skip the test if the corresponding grid dimension is equal to 1, i.e., a 2D slice.
    if (t == 2 .and. grid%nx == 1) cycle
    if (t == 3 .and. grid%ny == 1) cycle
    if (t == 4 .and. grid%nz == 1) cycle

    ! Performing the test.
    if (grid%i_(ind(t)) /= i_res(t) .or. &
        grid%j_(ind(t)) /= j_res(t) .or. &
        grid%k_(ind(t)) /= k_res(t)) then
      res = .false.
    endif
  enddo
end function test_grid_cell_order

!===============================================================================================================
! Calculates the sensitivity kernel (parallelized by data) and writes it to files.
!===============================================================================================================
subroutine calculate_and_write_sensit(par, grid_full, data, column_weight, nnz, nelements_new, myrank, nbproc)
  class(t_parameters_base), intent(in) :: par
  type(t_grid), intent(in) :: grid_full
  type(t_data), intent(in) :: data
  real(kind=CUSTOM_REAL), intent(in) :: column_weight(par%nelements)
  integer, intent(in) :: myrank, nbproc

  ! The number of non-zero elements (on current CPU) in the sensitivity kernel parallelized by model.
  ! We need this number for reading the sensitivity later from files, for invere problem.
  ! As the inverse problem is parallelized by model, and calculations here are parallelized by data.
  integer(kind=8), intent(out) :: nnz
  integer, intent(out) :: nelements_new

  type(t_magnetic_field) :: mag_field
  integer :: i, p, nel, ierr
  integer :: nelements_total, nel_compressed
  integer(kind=8) :: nnz_data
  integer :: problem_type
  integer :: idata, ndata_loc, ndata_smaller
  character(len=256) :: filename, filename_full
  real(kind=CUSTOM_REAL) :: comp_rate, comp_error
  integer(kind=8) :: nnz_total
  real(kind=CUSTOM_REAL) :: threshold
  character(len=256) :: msg

  integer :: nelements_at_cpu_new(nbproc)
  integer(kind=8) :: nnz_at_cpu_new(nbproc)

  ! Sensitivity matrix row.
  real(kind=CUSTOM_REAL), allocatable :: sensit_line_full(:)
  real(kind=CUSTOM_REAL), allocatable :: sensit_line_sorted(:)

  ! Arrays for storing the compressed sensitivity line.
  integer, allocatable :: sensit_columns(:)
  real(kind=MATRIX_PRECISION), allocatable :: sensit_compressed(:)

  ! To calculate the partitioning for balanced memory loading among CPUs.
  integer(kind=8), allocatable :: sensit_nnz(:)

  real(kind=CUSTOM_REAL) :: cost_full, cost_compressed
  real(kind=CUSTOM_REAL) :: cost_full_loc, cost_compressed_loc

  ! The full column weight.
  real(kind=CUSTOM_REAL), allocatable :: column_weight_full(:)

  ! Sanity check.
  if (par%compression_rate < 0 .or. par%compression_rate > 1) then
    call exit_MPI("Wrong compression rate! It must be between 0 and 1.", myrank, 0)
  endif

  ! Sanity check for the correct grid cells ordering.
  if (par%compression_rate > 0) then
    if (.not. test_grid_cell_order(par, grid_full)) then
      call exit_MPI("Wrong grid cells ordering in the grid file! Use the kji-loop order!", myrank, 0)
    endif
  endif

  ! Define the problem type.
  select type(par)
  class is (t_parameters_grav)
    if (myrank == 0) print *, 'Calculating GRAVITY sensitivity kernel...'
    problem_type = 1

  class is (t_parameters_mag)
    if (myrank == 0) print *, 'Calculating MAGNETIC sensitivity kernel...'
    problem_type = 2

    ! Precompute common magnetic parameters.
    call mag_field%initialize(par%mi, par%md, par%theta, par%intensity)
  end select

  !---------------------------------------------------------------------------------------------
  ! Define the output file.
  !---------------------------------------------------------------------------------------------
  call execute_command_line('mkdir -p '//trim(path_output)//"/SENSIT/")

  filename = "sensit_"//SUFFIX(problem_type)//"_"//trim(str(nbproc))//"_"//trim(str(myrank))
  filename_full = trim(path_output)//"/SENSIT/"//filename

  print *, 'Writing the sensitivity to file ', trim(filename_full)

  open(77, file=trim(filename_full), status='replace', access='stream', form='unformatted', action='write', &
       iostat=ierr, iomsg=msg)

  if (ierr /= 0) call exit_MPI("Error in creating the sensitivity file! path=" &
                               //trim(filename_full)//", iomsg="//msg, myrank, ierr)

  !---------------------------------------------------------------------------------------------
  ! Allocate memory.
  !---------------------------------------------------------------------------------------------
  nelements_total = par%nx * par%ny * par%nz

  if (par%compression_type > 0) then
    nel_compressed = max(int(par%compression_rate * nelements_total), 1)
  else
    nel_compressed = nelements_total
  endif
  if (myrank == 0) print *, 'nel_compressed =', nel_compressed

  allocate(sensit_line_full(nelements_total), source=0._CUSTOM_REAL, stat=ierr)
  allocate(sensit_line_sorted(nelements_total), source=0._CUSTOM_REAL, stat=ierr)
  allocate(column_weight_full(nelements_total), source=0._CUSTOM_REAL, stat=ierr)

  allocate(sensit_columns(nel_compressed), source=0, stat=ierr)
  allocate(sensit_compressed(nel_compressed), source=0._MATRIX_PRECISION, stat=ierr)

  allocate(sensit_nnz(nelements_total), source=int(0, 8), stat=ierr)

  if (ierr /= 0) call exit_MPI("Dynamic memory allocation error in calculate_and_write_sensit!", myrank, ierr)

  !---------------------------------------------------------------------------------------------
  ! Calculate sensitivity lines.
  !---------------------------------------------------------------------------------------------
  call get_full_array(column_weight, par%nelements, column_weight_full, .true., myrank, nbproc)

  ndata_loc = calculate_nelements_at_cpu(par%ndata, myrank, nbproc)
  ndata_smaller = get_nsmaller(ndata_loc, myrank, nbproc)

  ! File header.
  write(77) ndata_loc, par%ndata, nelements_total, myrank, nbproc

  nnz_data = 0
  cost_full_loc = 0.d0
  cost_compressed_loc = 0.d0

  ! Loop over the local data lines.
  do i = 1, ndata_loc
    ! Global data index.
    idata = ndata_smaller + i

    if (problem_type == 1) then
    ! Gravity problem.
      call graviprism_z(nelements_total, grid_full, data%X(idata), data%Y(idata), data%Z(idata), &
                        sensit_line_full, myrank)

    else if (problem_type == 2) then
    ! Magnetic problem.
      call mag_field%magprism(nelements_total, grid_full, data%X(idata), data%Y(idata), data%Z(idata), sensit_line_full)
    endif

    ! Applying the depth weight.
    call apply_column_weight(nelements_total, sensit_line_full, column_weight_full)

    if (par%compression_type > 0) then
    ! Wavelet compression.
      ! The uncompressed line cost.
      cost_full_loc = cost_full_loc + sum(sensit_line_full**2)

      ! Apply the wavelet transform.
      call Haar3D(sensit_line_full, par%nx, par%ny, par%nz)

      ! Perform sorting (to determine the wavelet threshold corresponding to the desired compression rate).
      sensit_line_sorted = abs(sensit_line_full)
      call quicksort(sensit_line_sorted, 1, nelements_total)

      ! Calculate the wavelet threshold corresponding to the desired compression rate.
      p = nelements_total - nel_compressed + 1
      threshold = abs(sensit_line_sorted(p))

      if (threshold < 1.d-30) then
        ! Keep small threshold to avoid extremely small values, because when MATRIX_PRECISION is 4 bytes real
        ! they lead to SIGFPE: Floating-point exception - erroneous arithmetic operation.
        threshold = 1.d-30
      endif

      nel = 0
      do p = 1, nelements_total
        if (abs(sensit_line_full(p)) >= threshold) then
          ! Store sensitivity elements greater than the wavelet threshold.
          nel = nel + 1
          sensit_columns(nel) = p
          sensit_compressed(nel) = real(sensit_line_full(p), MATRIX_PRECISION)

          sensit_nnz(p) = sensit_nnz(p) + 1
        endif
      enddo

      ! Sanity check.
      if (nel > nel_compressed) then
        call exit_MPI("Wrong number of elements in calculate_and_write_sensit!", myrank, 0)
      endif

      cost_compressed_loc = cost_compressed_loc + sum(sensit_compressed(1:nel)**2)

    else
    ! No compression.
      nel = nelements_total
      sensit_compressed = real(sensit_line_full, MATRIX_PRECISION)
      do p = 1, nelements_total
        sensit_columns(p) = p
        sensit_nnz(p) = sensit_nnz(p) + 1
      enddo
    endif

    ! The sensitivity kernel size (when parallelized by data).
    nnz_data = nnz_data + nel

    ! Sanity check.
    if (nnz_data < 0) then
      call exit_MPI("Integer overflow in nnz_data! Reduce the compression rate or increase the number of CPUs.", myrank, 0)
    endif

    ! Write the sensitivity line to file.
    write(77) idata, nel
    if (nel > 0) then
      write(77) sensit_columns(1:nel)
      write(77) sensit_compressed(1:nel)
    endif

    ! Print the progress.
    if (myrank == 0 .and. mod(i, max(int(0.1d0 * ndata_loc), 1)) == 0) then
      print *, 'Percent completed: ', int(dble(i) / dble(ndata_loc) * 100.d0)
    endif

  enddo ! data loop

  close(77)

  call mpi_allreduce(MPI_IN_PLACE, sensit_nnz, nelements_total, MPI_INTEGER8, MPI_SUM, MPI_COMM_WORLD, ierr)

  !---------------------------------------------------------------------------------------------
  ! Calculate the kernel compression rate.
  !---------------------------------------------------------------------------------------------
  call mpi_allreduce(nnz_data, nnz_total, 1, MPI_INTEGER8, MPI_SUM, MPI_COMM_WORLD, ierr)
  comp_rate = dble(nnz_total) / dble(nelements_total) / dble(par%ndata)

  if (myrank == 0) print *, 'nnz_total = ', nnz_total
  if (myrank == 0) print *, 'COMPRESSION RATE = ', comp_rate

  !---------------------------------------------------------------------------------------------
  ! Calculate the kernel compression error.
  !---------------------------------------------------------------------------------------------
  if (par%compression_type > 0) then
    call mpi_allreduce(cost_full_loc, cost_full, 1, CUSTOM_MPI_TYPE, MPI_SUM, MPI_COMM_WORLD, ierr)
    call mpi_allreduce(cost_compressed_loc, cost_compressed, 1, CUSTOM_MPI_TYPE, MPI_SUM, MPI_COMM_WORLD, ierr)
    comp_error = 1.d0 - sqrt(cost_compressed / cost_full)
  else
    comp_error = 0.d0
  endif

  if (myrank == 0) print *, 'COMPRESSION ERROR = ', comp_error

  !---------------------------------------------------------------------------------------------
  ! Perform the nnz load balancing among CPUs.
  !---------------------------------------------------------------------------------------------
  call get_load_balancing_nelements(nelements_total, sensit_nnz, nnz_total, &
                                    nnz_at_cpu_new, nelements_at_cpu_new, myrank, nbproc)

  if (myrank == 0) then
    print *, 'nnz_at_cpu_new: ', nnz_at_cpu_new
    print *, 'nelements_at_cpu_new: ', nelements_at_cpu_new
  endif

  nelements_new = nelements_at_cpu_new(myrank + 1)

  !---------------------------------------------------------------------------------------------
  ! Write the metadata file, with nnz info for re-reading sensitivity from files.
  !---------------------------------------------------------------------------------------------
  if (myrank == 0) then
    filename = "sensit_"//SUFFIX(problem_type)//"_"//trim(str(nbproc))//"_meta.dat"
    filename_full = trim(path_output)//"/SENSIT/"//filename

    print *, 'Writing the sensitivity metadata to file ', trim(filename_full)

    open(77, file=trim(filename_full), form='formatted', status='replace', action='write')

    write(77, *) par%nx, par%ny, par%nz, par%ndata, nbproc, MATRIX_PRECISION, comp_error
    write(77, *) nnz_at_cpu_new
    write(77, *) nelements_at_cpu_new

    close(77)
  endif

  !---------------------------------------------------------------------------------------------
  ! Write the depth weight.
  !---------------------------------------------------------------------------------------------
  if (myrank == 0) then
    filename = "sensit_"//SUFFIX(problem_type)//"_"//trim(str(nbproc))//"_weight"
    filename_full = trim(path_output)//"/SENSIT/"//filename

    print *, 'Writing the depth weight to file ', trim(filename_full)

    open(77, file=trim(filename_full), form='unformatted', status='replace', action='write', access='stream')

    write(77) par%nx, par%ny, par%nz, par%ndata, par%depth_weighting_type
    write(77) column_weight_full

    close(77)
  endif

  !---------------------------------------------------------------------------------------------
  ! Return the nnz for the current CPU.
  nnz = nnz_at_cpu_new(myrank + 1)

  !---------------------------------------------------------------------------------------------
  deallocate(sensit_line_full)
  deallocate(sensit_line_sorted)
  deallocate(column_weight_full)
  deallocate(sensit_columns)
  deallocate(sensit_compressed)
  deallocate(sensit_nnz)

  if (myrank == 0) print *, 'Finished calculating the sensitivity kernel.'

end subroutine calculate_and_write_sensit

!=======================================================================================================================
! Calculate new partitioning for the nnz and nelements at every CPU for the load balancing.
! The load balancing aims to have the same number of nnz at every CPU, which require using different nelements at CPUs.
!=======================================================================================================================
subroutine get_load_balancing_nelements(nelements_total, sensit_nnz, nnz_total, &
                                        nnz_at_cpu_new, nelements_at_cpu_new, myrank, nbproc)
  integer, intent(in) :: nelements_total
  integer(kind=8), intent(in) :: sensit_nnz(nelements_total)
  integer(kind=8), intent(in) :: nnz_total
  integer, intent(in) :: myrank, nbproc

  integer, intent(out) :: nelements_at_cpu_new(nbproc)
  integer(kind=8), intent(out) :: nnz_at_cpu_new(nbproc)

  integer :: cpu, p
  integer :: nelements_new
  integer(kind=8) :: nnz_new

  nnz_at_cpu_new(:) = nnz_total / int(nbproc, 8)
  ! Last rank gets the remaining elements.
  nnz_at_cpu_new(nbproc) = nnz_at_cpu_new(nbproc) + mod(nnz_total, int(nbproc, 8))

  cpu = 1
  nnz_new = 0
  nelements_new = 0

  do p = 1, nelements_total
    nnz_new = nnz_new + sensit_nnz(p)
    nelements_new = nelements_new + 1

    if (nnz_new > nnz_at_cpu_new(cpu) .or. p == nelements_total) then
      nnz_at_cpu_new(cpu) = nnz_new
      nelements_at_cpu_new(cpu) = nelements_new
      nnz_new = 0
      nelements_new = 0
      cpu = cpu + 1
    endif
  enddo

  if (sum(nnz_at_cpu_new) /= nnz_total) then
    call exit_MPI("Wrong nnz_at_cpu_new in get_load_balancing_nelements!", myrank, 0)
  endif
end subroutine get_load_balancing_nelements

!==================================================================================================================
! Reads the sensitivity kernel from files,
! and stores it in the sparse matrix parallelized by model.
!==================================================================================================================
subroutine read_sensitivity_kernel(par, sensit_matrix, column_weight, problem_weight, problem_type, myrank, nbproc)
  class(t_parameters_base), intent(in) :: par
  real(kind=CUSTOM_REAL), intent(in) :: problem_weight
  integer, intent(in) :: problem_type
  integer, intent(in) :: myrank, nbproc

  ! Sensitivity matrix.
  type(t_sparse_matrix), intent(inout) :: sensit_matrix
  real(kind=CUSTOM_REAL), intent(out) :: column_weight(par%nelements)

  ! Arrays for storing the compressed sensitivity line.
  integer, allocatable :: sensit_columns(:)
  real(kind=MATRIX_PRECISION), allocatable :: sensit_compressed(:)

  ! The full column weight.
  real(kind=CUSTOM_REAL), allocatable :: column_weight_full(:)

  real(kind=CUSTOM_REAL) :: comp_rate
  integer(kind=8) :: nnz_total
  integer :: i, j, p, nsmaller, ierr
  integer :: rank, nelements_total
  character(len=256) :: filename, filename_full
  character(len=256) :: msg

  integer :: ndata_loc, ndata_read, nelements_total_read, myrank_read, nbproc_read
  integer :: idata, nel, idata_glob
  integer(kind=8) :: nnz
  integer :: column
  integer :: param_shift(2)
  integer :: nx_read, ny_read, nz_read, weight_type_read

  param_shift(1) = 0
  param_shift(2) = par%nelements

  !---------------------------------------------------------------------------------------------
  ! Allocate memory.
  !---------------------------------------------------------------------------------------------
  nelements_total = par%nx * par%ny * par%nz

  allocate(sensit_columns(nelements_total), source=0, stat=ierr)
  allocate(sensit_compressed(nelements_total), source=0._MATRIX_PRECISION, stat=ierr)
  allocate(column_weight_full(nelements_total), source=0._CUSTOM_REAL, stat=ierr)

  if (ierr /= 0) call exit_MPI("Dynamic memory allocation error in read_sensitivity_kernel!", myrank, ierr)

  !---------------------------------------------------------------------------------------------
  ! Reading the sensitivity kernel files.
  !---------------------------------------------------------------------------------------------

  ! The number of elements on CPUs with rank smaller than myrank.
  nsmaller = get_nsmaller(par%nelements, myrank, nbproc)

  idata_glob = 0
  nnz = 0

  ! Loop over the MPI ranks (as the sensitivity kernel is stored parallelezied by data in a separate file for each rank).
  do rank = 0, nbproc - 1
    ! Form the file name (containing the MPI rank).
    filename = "sensit_"//SUFFIX(problem_type)//"_"//trim(str(nbproc))//"_"//trim(str(rank))

    if (par%sensit_read /= 0) then
      filename_full = trim(par%sensit_path)//filename
    else
      filename_full = trim(path_output)//"/SENSIT/"//filename
    endif

    if (myrank == 0) print *, 'Reading the sensitivity file ', trim(filename_full)

    open(78, file=trim(filename_full), status='old', access='stream', form='unformatted', action='read', &
         iostat=ierr, iomsg=msg)

    if (ierr /= 0) call exit_MPI("Error in opening the sensitivity file! path=" &
                                 //trim(filename_full)//", iomsg="//msg, myrank, ierr)

    ! Reading the file header.
    read(78) ndata_loc, ndata_read, nelements_total_read, myrank_read, nbproc_read

    ! Consistency check.
    if (ndata_read /= par%ndata .or. nelements_total_read /= nelements_total &
        .or. myrank_read /= rank .or. nbproc_read /= nbproc) then
      call exit_MPI("Wrong file header in read_sensitivity_kernel!", myrank, 0)
    endif

    ! Loop over the local data chunk within a file.
    do i = 1, ndata_loc
      idata_glob = idata_glob + 1

      ! Reading the data descriptor.
      read(78) idata, nel

      ! Make sure the data is stored in the correct order.
      if (idata /= idata_glob) then
        call exit_MPI("Wrong data index in read_sensitivity_kernel!", myrank, 0)
      endif

      if (nel > 0) then
        ! Reading the data.
        read(78) sensit_columns(1:nel)
        read(78) sensit_compressed(1:nel)
      endif

      ! Adding the matrix line.
      call sensit_matrix%new_row(myrank)

      do j = 1, nel
        p = sensit_columns(j)
        if (p > nsmaller .and. p <= nsmaller + par%nelements) then
        ! The element belongs to this rank. Adding it to the matrix.
          ! The column index in a big (joint) parallel sparse matrix.
          column = p - nsmaller + param_shift(problem_type)

          ! Add element to the sparse matrix.
          call sensit_matrix%add(sensit_compressed(j) * problem_weight, column, myrank)
          nnz = nnz + 1
        else
          if (p > nsmaller + par%nelements) exit
        endif
      enddo

    enddo ! data loop

    close(78)
  enddo

  call sensit_matrix%finalize_part()

  !---------------------------------------------------------------------------------------------
  ! Calculate the read kernel compression rate.
  !---------------------------------------------------------------------------------------------
  call mpi_allreduce(nnz, nnz_total, 1, MPI_INTEGER8, MPI_SUM, MPI_COMM_WORLD, ierr)
  comp_rate = dble(nnz_total) / dble(nelements_total) / dble(par%ndata)

  if (myrank == 0) print *, 'nnz_total (of the read kernel)  = ', nnz_total
  if (myrank == 0) print *, 'COMPRESSION RATE (of the read kernel)  = ', comp_rate

  !---------------------------------------------------------------------------------------------
  ! Read the depth weight
  !---------------------------------------------------------------------------------------------
  ! Define the file name.
  filename = "sensit_"//SUFFIX(problem_type)//"_"//trim(str(nbproc))//"_weight"

  if (par%sensit_read /= 0) then
    filename_full = trim(par%sensit_path)//filename
  else
    filename_full = trim(path_output)//"/SENSIT/"//filename
  endif

  if (myrank == 0) print *, "Reading the depth weight file ", trim(filename_full)

  ! Open the file.
  open(78, file=trim(filename_full), form='unformatted', status='old', action='read', access='stream', &
       iostat=ierr, iomsg=msg)

  if (ierr /= 0) call exit_MPI("Error in opening the depth weight file! path=" &
                                //trim(filename_full)//", iomsg="//msg, myrank, ierr)

  read(78) nx_read, ny_read, nz_read, ndata_read, weight_type_read
  read(78) column_weight_full

  close(78)

  if (myrank == 0) print *, "Depth weight type (read) =", weight_type_read

  ! Consistency check.
  if (nx_read /= par%nx .or. ny_read /= par%ny .or. nz_read /= par%nz .or. &
      ndata_read /= par%ndata) then
    call exit_MPI("Sensitivity weight file dimensions do not match the Parfile!", myrank, 0)
  endif

  ! Extract the column weight for the current rank.
  column_weight = column_weight_full(nsmaller + 1 : nsmaller + par%nelements)

  !---------------------------------------------------------------------------------------------
  deallocate(sensit_columns)
  deallocate(sensit_compressed)
  deallocate(column_weight_full)

  if (myrank == 0) print *, 'Finished reading the sensitivity kernel.'

end subroutine read_sensitivity_kernel

!=============================================================================================
! Reads the sensitivity kernel metadata and defines the nnz for re-reading the kernel.
!=============================================================================================
subroutine read_sensitivity_metadata(par, nnz, nelements_new, problem_type, myrank, nbproc)
  class(t_parameters_base), intent(in) :: par
  integer, intent(in) :: problem_type
  integer, intent(in) :: myrank, nbproc

  integer(kind=8), intent(out) :: nnz
  integer, intent(out) :: nelements_new

  integer(kind=8) :: nnz_at_cpu(nbproc)
  integer :: nelements_at_cpu_new(nbproc)
  integer :: ierr
  character(len=256) :: filename, filename_full
  character(len=256) :: msg
  integer :: nx_read, ny_read, nz_read, ndata_read, nbproc_read
  integer :: precision_read
  real(kind=CUSTOM_REAL) :: comp_error

  ! Define the file name.
  filename = "sensit_"//SUFFIX(problem_type)//"_"//trim(str(nbproc))//"_meta.dat"
  filename_full = trim(par%sensit_path)//filename

  if (myrank == 0) print *, "Reading the sensitivity metadata file ", trim(filename_full)

  ! Open the file.
  open(78, file=trim(filename_full), form='formatted', status='old', action='read', iostat=ierr, iomsg=msg)

  if (ierr /= 0) call exit_MPI("Error in opening the sensitivity metadata file! path=" &
                                //trim(filename_full)//", iomsg="//msg, myrank, ierr)

  read(78, *) nx_read, ny_read, nz_read, ndata_read, nbproc_read, precision_read, comp_error

  if (myrank == 0) print *, "COMPRESSION ERROR (read) =", comp_error

  ! Consistency check.
  if (nx_read /= par%nx .or. ny_read /= par%ny .or. nz_read /= par%nz .or. &
      ndata_read /= par%ndata .or. nbproc_read /= nbproc) then
    call exit_MPI("Sensitivity metadata file info does not match the Parfile!", myrank, 0)
  endif

  ! Matrix precision consistency check.
  if (precision_read /= MATRIX_PRECISION) then
    call exit_MPI("Matrix precision is not consistent!", myrank, 0)
  endif

  read(78, *) nnz_at_cpu
  read(78, *) nelements_at_cpu_new

  close(78)

  ! Return the parameters for the current rank.
  nnz = nnz_at_cpu(myrank + 1)
  nelements_new = nelements_at_cpu_new(myrank + 1)

end subroutine read_sensitivity_metadata

!==========================================================================================================
! Applying the column weight to sensitivity line.
!==========================================================================================================
subroutine apply_column_weight(nelements, sensit_line, column_weight)
  integer, intent(in) :: nelements
  real(kind=CUSTOM_REAL), intent(in) :: column_weight(nelements)

  real(kind=CUSTOM_REAL), intent(inout) :: sensit_line(nelements)

  integer :: i

  do i = 1, nelements
    sensit_line(i) = sensit_line(i) * column_weight(i)
  enddo

end subroutine apply_column_weight

end module sensitivity_gravmag
