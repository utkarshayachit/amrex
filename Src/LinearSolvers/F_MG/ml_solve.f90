module ml_solve_module

  use bl_types
  use mg_module
  use bndry_reg_module
  use ml_layout_module
  use multifab_module
  use define_bc_module
  use cc_stencil_fill_module
  use nodal_divu_module

  implicit none

  interface ml_cc_solve
     module procedure ml_cc_solve_1
     module procedure ml_cc_solve_2
  end interface

  interface ml_nd_solve
     module procedure ml_nd_solve_1
     module procedure ml_nd_solve_2
  end interface ml_nd_solve

  private

  public :: ml_cc_solve, ml_nd_solve

contains

  ! solve (alpha - del dot beta grad) full_soln = rhs for cell-centered full_soln
  ! only the first row of arguments is required; everything else is optional and will
  ! revert to defaults in mg_tower.f90 if not passed in
  subroutine ml_cc_solve_1(mla,rh,full_soln,fine_flx,alpha,beta,dx,the_bc_tower,bc_comp, &
                           nu1, nu2, nuf, nub, cycle_type, smoother, nc, ng, &
                           max_nlevel, max_bottom_nlevel, min_width, max_iter, &
                           abort_on_max_iter, eps, abs_eps, bottom_solver, &
                           bottom_max_iter, bottom_solver_eps, max_L0_growth, &
                           verbose, cg_verbose, use_hypre, &
                           fancy_bottom_type, use_lininterp, ptype, &
                           stencil_type, stencil_order, do_diagnostics)
    
    ! required arguments
    type(ml_layout), intent(in   ) :: mla
    type(multifab) , intent(inout) :: rh(:)         ! cell-centered
    type(multifab) , intent(inout) :: full_soln(:)  ! cell-centered
    type(bndry_reg), intent(inout) :: fine_flx(:)   ! boundary register
    type(multifab) , intent(in   ) :: alpha(:)      ! cell-centered
    type(multifab) , intent(in   ) :: beta(:,:)     ! edge-based
    real(kind=dp_t), intent(in   ) :: dx(:,:)
    type(bc_tower) , intent(in   ) :: the_bc_tower
    integer        , intent(in   ) :: bc_comp

    ! optional arguments
    integer, intent(in), optional :: nu1
    integer, intent(in), optional :: nu2
    integer, intent(in), optional :: nuf
    integer, intent(in), optional :: nub
    integer, intent(in), optional :: cycle_type
    integer, intent(in), optional :: smoother
    integer, intent(in), optional :: nc
    integer, intent(in), optional :: ng
    integer, intent(in), optional :: max_nlevel
    integer, intent(in), optional :: max_bottom_nlevel
    integer, intent(in), optional :: min_width
    integer, intent(in), optional :: max_iter
    logical, intent(in), optional :: abort_on_max_iter
    real(kind=dp_t), intent(in), optional :: eps
    real(kind=dp_t), intent(in), optional :: abs_eps
    integer, intent(in), optional :: bottom_solver
    integer, intent(in), optional :: bottom_max_iter
    real(kind=dp_t), intent(in), optional :: bottom_solver_eps
    real(kind=dp_t), intent(in), optional :: max_L0_growth
    integer, intent(in), optional :: verbose
    integer, intent(in), optional :: cg_verbose
    integer, intent(in), optional :: use_hypre
    integer, intent(in), optional :: fancy_bottom_type
    logical, intent(in), optional :: use_lininterp
    integer, intent(in), optional :: ptype
    integer, intent(in), optional :: stencil_type
    integer, intent(in), optional :: stencil_order
    integer, intent(in), optional :: do_diagnostics

    ! local
    logical :: is_parabolic

    type(mg_tower) :: mgt(mla%nlevel)

    type(layout) :: la

    integer :: stencil_order_in, do_diagnostics_in
    integer :: i, dm, n, nlevs

    type(multifab), allocatable :: cell_coeffs(:)
    type(multifab), allocatable :: edge_coeffs(:,:)

    real(dp_t) ::  xa(mla%dim),  xb(mla%dim)
    real(dp_t) :: pxa(mla%dim), pxb(mla%dim)

    dm = mla%dim
    nlevs = mla%nlevel

    do_diagnostics_in = 0
    stencil_order_in = 2

    if (present(do_diagnostics)) do_diagnostics_in = do_diagnostics
    if (present(stencil_order))  stencil_order_in = stencil_order

    ! Am I doing a parabolic or elliptic solve?
    if (multifab_norm_inf(alpha(1)) .gt. 0.) then
      is_parabolic = .true.
    else
      is_parabolic = .false.
    end if

    do n=1,nlevs
       
       if (present(stencil_type)) then
          mgt(n)%stencil_type = stencil_type
       else
          mgt(n)%stencil_type = CC_CROSS_STENCIL
       end if
       if (present(nu1))                  mgt(n)%nu1 = nu1 ! # of smooths at each level on the way down
       if (present(nu2))                  mgt(n)%nu2 = nu2 ! # of smooths at each level on the way up
       if (present(nuf))                  mgt(n)%nuf = nuf
       if (present(nub))                  mgt(n)%nub = nub ! # of smooths before and after bottom solver
       if (present(cycle_type))           mgt(n)%cycle_type = cycle_type ! choose between V-cycle, W-cycle, etc.
       if (present(smoother))             mgt(n)%smoother = smoother ! smoother type
       if (present(nc))                   mgt(n)%nc = nc
       if (present(ng))                   mgt(n)%ng = ng
       ! max_nlevel represents how many levels you can coarsen before you either reach
       ! the bottom solve, or the mg_tower object at the next coarser level of refinement
       if (n .eq. 1) then
          if (present(max_nlevel)) mgt(n)%max_nlevel = max_nlevel
       else
          mgt(n)%max_nlevel = 1
       end if
       if (present(max_bottom_nlevel))    mgt(n)%max_bottom_nlevel = max_bottom_nlevel ! additional coarsening if you use bottom_solver type 4
       if (present(min_width))            mgt(n)%min_width = min_width ! minimum size of grid at coarsest multigrid level
       if (present(max_iter))             mgt(n)%max_iter = max_iter ! maximum number of v-cycles
       if (present(abort_on_max_iter))    mgt(n)%abort_on_max_iter = abort_on_max_iter
       if (present(eps))                  mgt(n)%eps = eps ! relative tolerance of solver
       if (present(abs_eps))              mgt(n)%abs_eps = abs_eps ! absolute tolerance of solver
       if (present(bottom_solver))        mgt(n)%bottom_solver = bottom_solver ! bottom solver type
       if (present(bottom_max_iter))      mgt(n)%bottom_max_iter = bottom_max_iter ! max iterations of bottom solver
       if (present(bottom_solver_eps))    mgt(n)%bottom_solver_eps = bottom_solver_eps ! tolerance of bottom solver
       if (present(max_L0_growth))        mgt(n)%max_L0_growth = max_L0_growth
       if (present(verbose))              mgt(n)%verbose = verbose ! verbosity
       if (present(cg_verbose))           mgt(n)%cg_verbose = cg_verbose ! bottom solver verbosity
       if (present(use_hypre))            mgt(n)%use_hypre = use_hypre
       if (present(fancy_bottom_type))    mgt(n)%fancy_bottom_type = fancy_bottom_type
       if (present(use_lininterp))        mgt(n)%use_lininterp = use_lininterp
       if (present(ptype))                mgt(n)%ptype = ptype

       ! build the mg_tower object at level n
       if (is_parabolic) then
          call mg_tower_build(mgt(n), mla%la(n), layout_get_pd(mla%la(n)), &
                              the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,bc_comp), &
                              stencil_type = mgt(n)%stencil_type, &
                              nu1 = mgt(n)%nu1, &
                              nu2 = mgt(n)%nu2, &
                              nuf = mgt(n)%nuf, &
                              nub = mgt(n)%nub, &
                              cycle_type = mgt(n)%cycle_type, &
                              smoother = mgt(n)%smoother, &
                              dh = dx(n,:), &
                              nc = mgt(n)%nc, &
                              ng = mgt(n)%ng, &
                              max_nlevel = mgt(n)%max_nlevel, &
                              max_bottom_nlevel = mgt(n)%max_bottom_nlevel, &
                              min_width = mgt(n)%min_width, &
                              max_iter = mgt(n)%max_iter, &
                              abort_on_max_iter = mgt(n)%abort_on_max_iter, &
                              eps = mgt(n)%eps, &
                              abs_eps = mgt(n)%abs_eps, &
                              bottom_solver = mgt(n)%bottom_solver, &
                              bottom_max_iter = mgt(n)%bottom_max_iter, &
                              bottom_solver_eps = mgt(n)%bottom_solver_eps, &
                              max_L0_growth = mgt(n)%max_L0_growth, &
                              verbose = mgt(n)%verbose, &
                              cg_verbose = mgt(n)%cg_verbose, &
                              nodal = nodal_flags(rh(nlevs)), &
                              use_hypre = mgt(n)%use_hypre,&
                              is_singular = .false., &
                              fancy_bottom_type = mgt(n)%fancy_bottom_type, &
                              use_lininterp = mgt(n)%use_lininterp, &
                              ptype = mgt(n)%ptype)
       else
          call mg_tower_build(mgt(n), mla%la(n), layout_get_pd(mla%la(n)), &
                              the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,bc_comp), &
                              stencil_type = mgt(n)%stencil_type, &
                              nu1 = mgt(n)%nu1, &
                              nu2 = mgt(n)%nu2, &
                              nuf = mgt(n)%nuf, &
                              nub = mgt(n)%nub, &
                              cycle_type = mgt(n)%cycle_type, &
                              smoother = mgt(n)%smoother, &
                              dh = dx(n,:), &
                              nc = mgt(n)%nc, &
                              ng = mgt(n)%ng, &
                              max_nlevel = mgt(n)%max_nlevel, &
                              max_bottom_nlevel = mgt(n)%max_bottom_nlevel, &
                              min_width = mgt(n)%min_width, &
                              max_iter = mgt(n)%max_iter, &
                              abort_on_max_iter = mgt(n)%abort_on_max_iter, &
                              eps = mgt(n)%eps, &
                              abs_eps = mgt(n)%abs_eps, &
                              bottom_solver = mgt(n)%bottom_solver, &
                              bottom_max_iter = mgt(n)%bottom_max_iter, &
                              bottom_solver_eps = mgt(n)%bottom_solver_eps, &
                              max_L0_growth = mgt(n)%max_L0_growth, &
                              verbose = mgt(n)%verbose, &
                              cg_verbose = mgt(n)%cg_verbose, &
                              nodal = nodal_flags(rh(nlevs)), &
                              use_hypre = mgt(n)%use_hypre,&
                              fancy_bottom_type = mgt(n)%fancy_bottom_type, &
                              use_lininterp = mgt(n)%use_lininterp, &
                              ptype = mgt(n)%ptype)
       end if
    end do

    ! Fill coefficient array
    do n = nlevs,1,-1

       allocate(cell_coeffs(mgt(n)%nlevels))
       allocate(edge_coeffs(mgt(n)%nlevels,dm))

       la = mla%la(n)

       ! we will use this to tell mgt about alpha
       call multifab_build(cell_coeffs(mgt(n)%nlevels), la, 1, 1)
       call multifab_copy_c(cell_coeffs(mgt(n)%nlevels),1,alpha(n),1,1,alpha(n)%ng)

       ! we will use this to tell mgt about beta
       do i=1,dm
          call multifab_build_edge(edge_coeffs(mgt(n)%nlevels,i),la,1,1,i)
          call multifab_copy_c(edge_coeffs(mgt(n)%nlevels,i),1,beta(n,i),1,1,beta(n,i)%ng)
       end do

       ! xa and xb tell the stencil how far away the ghost cell values are in physical
       ! dimensions from the edge of the grid
       if (n > 1) then
          xa = HALF*mla%mba%rr(n-1,:)*mgt(n)%dh(:,mgt(n)%nlevels)
          xb = HALF*mla%mba%rr(n-1,:)*mgt(n)%dh(:,mgt(n)%nlevels)
       else
          xa = ZERO
          xb = ZERO
       end if

       ! xa and xb tell the stencil how far away the ghost cell values are in physical
       ! dimensions from the edge of the grid if the grid is at the domain boundary
       pxa = ZERO
       pxb = ZERO

       ! tell mgt about alpha, beta, xa, xb, pxa, and pxb
       call stencil_fill_cc_all_mglevels(mgt(n), cell_coeffs, edge_coeffs, xa, xb, &
                                         pxa, pxb, stencil_order_in, &
                                         the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,bc_comp))

       ! deallocate memory
       call destroy(cell_coeffs(mgt(n)%nlevels))
       do i=1,dm
          call destroy(edge_coeffs(mgt(n)%nlevels,i))
       end do
       deallocate(cell_coeffs)
       deallocate(edge_coeffs)

    end do

    ! solve (alpha - del dot beta grad) phi = rhs to obtain phi
    call ml_cc_solve(mla, mgt, rh, full_soln, fine_flx, do_diagnostics_in)

    ! deallocate memory
    do n=1,nlevs
       call mg_tower_destroy(mgt(n))
    end do

  end subroutine ml_cc_solve_1

  subroutine ml_cc_solve_2(mla,mgt,rh,full_soln,fine_flx,do_diagnostics)

    use ml_cc_module , only : ml_cc

    type(ml_layout), intent(in   ) :: mla
    type(mg_tower ), intent(inout) :: mgt(:)
    type(multifab ), intent(inout) :: rh(:)
    type(multifab ), intent(inout) :: full_soln(:)
    type(bndry_reg), intent(inout) :: fine_flx(2:)
    integer        , intent(in   ) :: do_diagnostics

    type(boxarray)  :: bac
    type(lmultifab) :: fine_mask(mla%nlevel)
    integer         :: i, dm, n, nlevs, mglev

    dm    = mla%dim
    nlevs = mla%nlevel

    do n = nlevs, 1, -1
       call lmultifab_build(fine_mask(n), mla%la(n), 1, 0)
       call setval(fine_mask(n), val = .true., all = .true.)
    end do
    do n = nlevs-1, 1, -1
       call copy(bac, get_boxarray(mla%la(n+1)))
       call boxarray_coarsen(bac, mla%mba%rr(n,:))
       call setval(fine_mask(n), .false., bac)
       call destroy(bac)
    end do

    ! ****************************************************************************

    call ml_cc(mla,mgt,rh,full_soln,fine_mask,do_diagnostics, &
         need_grad_phi_in=.true.)

    ! ****************************************************************************

    !   Put boundary conditions of soln in fine_flx to get correct grad(phi) at
    !     crse-fine boundaries (after soln correctly interpolated in ml_cc)
    do n = 2,nlevs
       mglev = mgt(n)%nlevels
       do i = 1, dm
          call ml_fill_fine_fluxes(mgt(n)%ss(mglev), fine_flx(n)%bmf(i,0), &
                                   full_soln(n), mgt(n)%mm(mglev), -1, i, &
                                   mgt(n)%lcross)
          call ml_fill_fine_fluxes(mgt(n)%ss(mglev), fine_flx(n)%bmf(i,1), &
                                   full_soln(n), mgt(n)%mm(mglev),  1, i, &
                                   mgt(n)%lcross)
       end do
    end do

    do n = 1,nlevs
       call lmultifab_destroy(fine_mask(n))
    end do

  end subroutine ml_cc_solve_2

  subroutine ml_fill_fine_fluxes(ss, flux, uu, mm, face, dim, lcross)

    use bl_prof_module
    use cc_stencil_apply_module

    type(multifab) , intent(inout) :: flux
    type(multifab) , intent(in   ) :: ss
    type(multifab) , intent(inout) :: uu
    type(imultifab), intent(in   ) :: mm
    integer        , intent(in   ) :: face, dim
    logical        , intent(in   ) :: lcross

    integer :: i, n
    real(kind=dp_t), pointer :: fp(:,:,:,:)
    real(kind=dp_t), pointer :: up(:,:,:,:)
    real(kind=dp_t), pointer :: sp(:,:,:,:)
    integer        , pointer :: mp(:,:,:,:)
    integer :: ng
    type(bl_prof_timer), save :: bpt

    call build(bpt, "ml_fill_fine_fluxes")

    ng = nghost(uu)

    if ( ncomp(uu) /= ncomp(flux) ) then
       call bl_error("ML_FILL_FINE_FLUXES: uu%nc /= flux%nc")
    end if

    call multifab_fill_boundary(uu, cross = lcross)

    !$OMP PARALLEL DO PRIVATE(i,n,fp,up,sp,mp)
    do i = 1, nfabs(flux)
       fp => dataptr(flux, i)
       up => dataptr(uu, i)
       sp => dataptr(ss, i)
       mp => dataptr(mm, i)
       do n = 1, ncomp(uu)
          select case(get_dim(ss))
          case (1)
             call stencil_fine_flux_1d(sp(:,:,1,1), fp(:,1,1,n), up(:,1,1,n), &
                                       mp(:,1,1,1), ng, face, dim)
          case (2)
             call stencil_fine_flux_2d(sp(:,:,:,1), fp(:,:,1,n), up(:,:,1,n), &
                                       mp(:,:,1,1), ng, face, dim)
          case (3)
             call stencil_fine_flux_3d(sp(:,:,:,:), fp(:,:,:,n), up(:,:,:,n), &
                                       mp(:,:,:,1), ng, face, dim)
          end select
       end do
    end do
    !$OMP END PARALLEL DO

    call destroy(bpt)

  end subroutine ml_fill_fine_fluxes

  !
  ! ******************************************************************************************
  !


  ! solve  "-(del dot beta grad) full_soln = rh" for nodal full_soln
  ! rh is nodal and beta is cell-centered.
  ! alpha is not supported yet
  ! only the first row of arguments is required; everything else is optional and will
  ! revert to defaults in mg_tower.f90 if not passed in.
  ! if subtract_divu=.true., this subroutine will compute div(u) and instead solve
  ! -(del dot beta grad) full_soln = rh - div(u)
  ! Thus, if you are doing a projection method where div(u)=S, you want to solve
  ! -(del dot beta grad) full_soln = S - div(u), and thus you should pass in "+S" for rh
  ! and pass in subtract_divu=.true.
  subroutine ml_nd_solve_1(mla,rh,full_soln,beta,dx,the_bc_tower,bc_comp, &
                           subtract_divu, u, &
                           nu1, nu2, nuf, nub, cycle_type, smoother, nc, ng, &
                           max_nlevel, max_bottom_nlevel, min_width, max_iter, &
                           abort_on_max_iter, eps, abs_eps, bottom_solver, &
                           bottom_max_iter, bottom_solver_eps, max_L0_growth, &
                           verbose, cg_verbose, use_hypre, &
                           fancy_bottom_type, use_lininterp, ptype, &
                           stencil_type, stencil_order, do_diagnostics)
    
    use nodal_stencil_fill_module , only : stencil_fill_nodal_all_mglevels

    ! required arguments
    type(ml_layout), intent(in   ) :: mla
    type(multifab) , intent(inout) :: rh(:)         ! nodal
    type(multifab) , intent(inout) :: full_soln(:)  ! nodal
    type(multifab) , intent(in   ) :: beta(:)       ! cell-centered
    real(kind=dp_t), intent(in   ) :: dx(:,:)
    type(bc_tower) , intent(in   ) :: the_bc_tower
    integer        , intent(in   ) :: bc_comp

    ! optional arguments
    logical, intent(in), optional :: subtract_divu
    type(multifab), intent(inout), optional :: u(:) ! cell-centered
    integer, intent(in), optional :: nu1
    integer, intent(in), optional :: nu2
    integer, intent(in), optional :: nuf
    integer, intent(in), optional :: nub
    integer, intent(in), optional :: cycle_type
    integer, intent(in), optional :: smoother
    integer, intent(in), optional :: nc
    integer, intent(in), optional :: ng
    integer, intent(in), optional :: max_nlevel
    integer, intent(in), optional :: max_bottom_nlevel
    integer, intent(in), optional :: min_width
    integer, intent(in), optional :: max_iter
    logical, intent(in), optional :: abort_on_max_iter
    real(kind=dp_t), intent(in), optional :: eps
    real(kind=dp_t), intent(in), optional :: abs_eps
    integer, intent(in), optional :: bottom_solver
    integer, intent(in), optional :: bottom_max_iter
    real(kind=dp_t), intent(in), optional :: bottom_solver_eps
    real(kind=dp_t), intent(in), optional :: max_L0_growth
    integer, intent(in), optional :: verbose
    integer, intent(in), optional :: cg_verbose
    integer, intent(in), optional :: use_hypre
    integer, intent(in), optional :: fancy_bottom_type
    logical, intent(in), optional :: use_lininterp
    integer, intent(in), optional :: ptype
    integer, intent(in), optional :: stencil_type
    integer, intent(in), optional :: stencil_order
    integer, intent(in), optional :: do_diagnostics

    ! local
    integer :: i,dm,n,nlevs
    integer :: do_diagnostics_in, stencil_order_in
    logical :: subtract_divu_in

    type(mg_tower) :: mgt(mla%nlevel)

    type(multifab), allocatable :: coeffs(:)
    integer :: lo_inflow(mla%dim),hi_inflow(mla%dim)

    type(multifab) :: divu_tmp(mla%nlevel)

    dm = mla%dim
    nlevs = mla%nlevel

    do_diagnostics_in = 0
    stencil_order_in = 2
    subtract_divu_in = .false.

    if (present(do_diagnostics)) do_diagnostics_in = do_diagnostics
    if (present(stencil_order))  stencil_order_in = stencil_order
    if (present(subtract_divu))  subtract_divu_in = subtract_divu

    do n=1,nlevs
       
       if (present(stencil_type)) then
          mgt(n)%stencil_type = stencil_type
       else
          mgt(n)%stencil_type = ND_DENSE_STENCIL
       end if
       if (present(nu1))                  mgt(n)%nu1 = nu1 ! # of smooths at each level on the way down
       if (present(nu2))                  mgt(n)%nu2 = nu2 ! # of smooths at each level on the way up
       if (present(nuf))                  mgt(n)%nuf = nuf
       if (present(nub))                  mgt(n)%nub = nub ! # of smooths before and after bottom solver
       if (present(cycle_type))           mgt(n)%cycle_type = cycle_type ! choose between V-cycle, W-cycle, etc.
       if (present(smoother))             mgt(n)%smoother = smoother ! smoother type
       if (present(nc))                   mgt(n)%nc = nc
       if (present(ng))                   mgt(n)%ng = ng
       ! max_nlevel represents how many levels you can coarsen before you either reach
       ! the bottom solve, or the mg_tower object at the next coarser level of refinement
       if (n .eq. 1) then
          if (present(max_nlevel)) mgt(n)%max_nlevel = max_nlevel
       else
          mgt(n)%max_nlevel = 1
       end if
       if (present(max_bottom_nlevel))    mgt(n)%max_bottom_nlevel = max_bottom_nlevel ! additional coarsening if you use bottom_solver type 4
       if (present(min_width))            mgt(n)%min_width = min_width ! minimum size of grid at coarsest multigrid level
       if (present(max_iter))             mgt(n)%max_iter = max_iter ! maximum number of v-cycles
       if (present(abort_on_max_iter))    mgt(n)%abort_on_max_iter = abort_on_max_iter
       if (present(eps))                  mgt(n)%eps = eps ! relative tolerance of solver
       if (present(abs_eps))              mgt(n)%abs_eps = abs_eps ! absolute tolerance of solver
       if (present(bottom_solver))        mgt(n)%bottom_solver = bottom_solver ! bottom solver type
       if (present(bottom_max_iter))      mgt(n)%bottom_max_iter = bottom_max_iter ! max iterations of bottom solver
       if (present(bottom_solver_eps))    mgt(n)%bottom_solver_eps = bottom_solver_eps ! tolerance of bottom solver
       if (present(max_L0_growth))        mgt(n)%max_L0_growth = max_L0_growth
       if (present(verbose))              mgt(n)%verbose = verbose ! verbosity
       if (present(cg_verbose))           mgt(n)%cg_verbose = cg_verbose ! bottom solver verbosity
       if (present(use_hypre))            mgt(n)%use_hypre = use_hypre
       if (present(fancy_bottom_type))    mgt(n)%fancy_bottom_type = fancy_bottom_type
       if (present(use_lininterp))        mgt(n)%use_lininterp = use_lininterp
       if (present(ptype))                mgt(n)%ptype = ptype

       call mg_tower_build(mgt(n), mla%la(n), layout_get_pd(mla%la(n)), &
                           the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,bc_comp), &
                           stencil_type = mgt(n)%stencil_type, &
                           nu1 = mgt(n)%nu1, &
                           nu2 = mgt(n)%nu2, &
                           nuf = mgt(n)%nuf, &
                           nub = mgt(n)%nub, &
                           cycle_type = mgt(n)%cycle_type, &
                           smoother = mgt(n)%smoother, &
                           dh = dx(n,:), &
                           nc = mgt(n)%nc, &
                           ng = mgt(n)%ng, &
                           max_nlevel = mgt(n)%max_nlevel, &
                           max_bottom_nlevel = mgt(n)%max_bottom_nlevel, &
                           min_width = mgt(n)%min_width, &
                           max_iter = mgt(n)%max_iter, &
                           abort_on_max_iter = mgt(n)%abort_on_max_iter, &
                           eps = mgt(n)%eps, &
                           abs_eps = mgt(n)%abs_eps, &
                           bottom_solver = mgt(n)%bottom_solver, &
                           bottom_max_iter = mgt(n)%bottom_max_iter, &
                           bottom_solver_eps = mgt(n)%bottom_solver_eps, &
                           max_L0_growth = mgt(n)%max_L0_growth, &
                           verbose = mgt(n)%verbose, &
                           cg_verbose = mgt(n)%cg_verbose, &
                           nodal = nodal_flags(rh(nlevs)), &
                           use_hypre = mgt(n)%use_hypre,&
                           fancy_bottom_type = mgt(n)%fancy_bottom_type, &
                           use_lininterp = mgt(n)%use_lininterp, &
                           ptype = mgt(n)%ptype)
    end do



    do n = nlevs,1,-1

       allocate(coeffs(mgt(n)%nlevels))

       call multifab_build(coeffs(mgt(n)%nlevels), mla%la(n), 1, 1)
       call multifab_copy_c(coeffs(mgt(n)%nlevels),1,beta(n),1,1,beta(n)%ng)

       call stencil_fill_nodal_all_mglevels(mgt(n), coeffs)

       call destroy(coeffs(mgt(n)%nlevels))
       deallocate(coeffs)

    end do

    ! ********************************************************************************
    ! add divu_tmp to rhs (optional)
    ! ********************************************************************************
    
    if (subtract_divu_in) then

       if (.not.(present(u))) then
          call bl_error('ml_solve.f90: subtract_divu_in requires u passed in')
       end if

       ! Set the inflow array -- 1 if inflow, otherwise 0
       lo_inflow(:) = 0
       hi_inflow(:) = 0
       do i=1,dm
          if (the_bc_tower%bc_tower_array(1)%phys_bc_level_array(0,i,1) == INLET) then
             lo_inflow(i) = 1
          end if
          if (the_bc_tower%bc_tower_array(1)%phys_bc_level_array(0,i,2) == INLET) then
             hi_inflow(i) = 1
          end if
       end do
       
       do n=1,nlevs
          call multifab_build_nodal(divu_tmp(n),mla%la(n),1,1)
       end do

       call divu(nlevs,mgt,u,divu_tmp,mla%mba%rr,nodal_flags(divu_tmp(nlevs)),lo_inflow,hi_inflow)
 
       ! Do rh = rh - divu_tmp (this routine preserves rh=0 on nodes which have bc_dirichlet = true.)
       call enforce_outflow_on_divu_rhs(rh,the_bc_tower)
       call subtract_divu_from_rh(nlevs,mgt,rh,divu_tmp)

       ! not sure about this... makes varden regression work but need to think about it
       do n=1,nlevs
          call multifab_mult_mult_s_c(rh(n),1,-1.d0,1,1)
       end do

    end if

    call ml_nd_solve_2(mla,mgt,rh,full_soln,do_diagnostics_in)

    do n=1,nlevs
       call mg_tower_destroy(mgt(n))
       call multifab_destroy(divu_tmp(n))
    end do

  end subroutine ml_nd_solve_1

  subroutine ml_nd_solve_2(mla,mgt,rh,full_soln,do_diagnostics)

    use ml_nd_module, only : ml_nd

    type(ml_layout), intent(in   )           :: mla
    type(mg_tower) , intent(inout)           :: mgt(:)
    type(multifab) , intent(inout)           :: rh(:)
    type(multifab) , intent(inout)           :: full_soln(:)
    integer        , intent(in   )           :: do_diagnostics 

    type(lmultifab) :: fine_mask(mla%nlevel)
    integer         :: nlevs, n, dm
    logical         :: nodal(get_dim(rh(mla%nlevel)))

    nlevs = mla%nlevel
    dm    = get_dim(rh(nlevs))
    nodal = .true.

    !      We are only considering the dense stencils here (3 in 1d, 9 in 2d, 27 in 3d)

    do n = nlevs, 1, -1
       call lmultifab_build(fine_mask(n), mla%la(n), 1, 0, nodal)
       if ( n < nlevs ) then
          call create_nodal_mask(fine_mask(n), &
                                 mgt(n  )%mm(mgt(n  )%nlevels), &
                                 mgt(n+1)%mm(mgt(n+1)%nlevels), &
                                 mla%mba%rr(n,:))
       else
          call setval(fine_mask(n), val = .true., all = .true.)
       endif
    end do

    call ml_nd(mla,mgt,rh,full_soln,fine_mask,do_diagnostics)

    do n = 1,nlevs
       call lmultifab_destroy(fine_mask(n))
    end do

  end subroutine ml_nd_solve_2

  subroutine create_nodal_mask(mask,mm_crse,mm_fine,ir)

    type(lmultifab), intent(inout) :: mask
    type(imultifab), intent(in   ) :: mm_crse
    type(imultifab), intent(in   ) :: mm_fine
    integer        , intent(in   ) :: ir(:)

    type(box)                        :: cbox, fbox, isect
    type(boxarray)                   :: ba
    type(layout)                     :: la
    logical,               pointer   :: mkp(:,:,:,:)
    integer                          :: loc(get_dim(mask)), lof(get_dim(mask)), i, j, k, dims(4), proc, dm, ii, jj
    integer,               pointer   :: cmp(:,:,:,:), fmp(:,:,:,:)
    integer                          :: lo(get_dim(mask)), hi(get_dim(mask))
    integer,               parameter :: tag = 1071
    type(box_intersector), pointer   :: bi(:)
    type(bl_prof_timer),   save      :: bpt

    if ( .not. nodal_q(mask) ) call bl_error('create_nodal_mask(): mask NOT nodal')

    call build(bpt, "create_nodal_mask")

    call setval(mask, .true.)
    !
    ! Need to build temporary layout with nodal boxarray for the intersection tests below.
    !
    call copy(ba, get_boxarray(get_layout(mask)))
    call boxarray_nodalize(ba, nodal_flags(mask))
    call build(la, ba, boxarray_bbox(ba), mapping = LA_LOCAL)  ! LA_LOCAL ==> bypass processor distribution calculation.
    call destroy(ba)
    !
    !   Note :          mm_fine is  in fine space
    !   Note : mask and mm_crse are in crse space
    !
    dims = 1

    dm = get_dim(mask)

    do i = 1, nboxes(mm_fine%la)

       fbox =  box_nodalize(get_box(mm_fine%la,i),mm_fine%nodal)
       bi   => layout_get_box_intersector(la, coarsen(fbox,ir))

       do k = 1, size(bi)
          j = bi(k)%i

          if ( remote(mask%la,j) .and. remote(mm_fine%la,i) ) cycle

          cbox  = box_nodalize(get_box(mask%la,j),mask%nodal)
          loc   = lwb(cbox)
          isect = bi(k)%bx
          lo    = lwb(isect)
          hi    = upb(isect)

          if ( local(mask%la,j) .and. local(mm_fine%la,i) ) then
             ii  =  local_index(mm_fine,i)
             jj  =  local_index(mask,j)
             lof =  lwb(fbox)
             mkp => dataptr(mask,jj)
             cmp => dataptr(mm_crse,jj)
             fmp => dataptr(mm_fine,ii)

             select case (dm)
             case (1)
                call create_nodal_mask_1d(mkp(:,1,1,1),cmp(:,1,1,1),loc,fmp(:,1,1,1),lof,lo,hi,ir)
             case (2)
                call create_nodal_mask_2d(mkp(:,:,1,1),cmp(:,:,1,1),loc,fmp(:,:,1,1),lof,lo,hi,ir)
             case (3)
                call create_nodal_mask_3d(mkp(:,:,:,1),cmp(:,:,:,1),loc,fmp(:,:,:,1),lof,lo,hi,ir)
             end select
          else if ( local(mm_fine%la,i) ) then
             !
             ! Must send mm_fine.
             !
             ii    =  local_index(mm_fine,i)
             isect =  intersection(refine(isect,ir),fbox)
             fmp   => dataptr(mm_fine, ii, isect)
             proc  =  get_proc(get_layout(mask), j)
             call parallel_send(fmp, proc, tag)
          else if ( local(mask%la,j) ) then
             !
             ! Must receive mm_fine.
             !
             jj    =  local_index(mask,j)
             isect =  intersection(refine(isect,ir),fbox)
             lof   =  lwb(isect)
             mkp   => dataptr(mask,jj)
             cmp   => dataptr(mm_crse,jj)
             proc  =  get_proc(get_layout(mm_fine),i)

             dims(1:dm) = extent(isect)
             allocate(fmp(dims(1),dims(2),dims(3),1))
             call parallel_recv(fmp, proc, tag)

             select case (dm)
             case (1)
                call create_nodal_mask_1d(mkp(:,1,1,1),cmp(:,1,1,1),loc,fmp(:,1,1,1),lof,lo,hi,ir)
             case (2)
                call create_nodal_mask_2d(mkp(:,:,1,1),cmp(:,:,1,1),loc,fmp(:,:,1,1),lof,lo,hi,ir)
             case (3)
                call create_nodal_mask_3d(mkp(:,:,:,1),cmp(:,:,:,1),loc,fmp(:,:,:,1),lof,lo,hi,ir)
             end select

             deallocate(fmp)
          end if
       end do
       deallocate(bi)
    end do

    call destroy(la)
    call destroy(bpt)

  end subroutine create_nodal_mask

  subroutine create_nodal_mask_1d(mask,mm_crse,loc,mm_fine,lof,lo,hi,ir)

    integer, intent(in   ) :: loc(:),lof(:)
    logical, intent(inout) ::    mask(loc(1):)
    integer, intent(in   ) :: mm_crse(loc(1):)
    integer, intent(in   ) :: mm_fine(lof(1):)
    integer, intent(in   ) :: lo(:),hi(:)
    integer, intent(in   ) :: ir(:)

    integer :: i,fi

    do i = lo(1),hi(1)
       fi = i*ir(1)
       if (.not.  bc_dirichlet(mm_fine(fi),1,0) .or. bc_dirichlet(mm_crse(i),1,0)) &
            mask(i) = .false.
    end do

  end subroutine create_nodal_mask_1d

  subroutine create_nodal_mask_2d(mask,mm_crse,loc,mm_fine,lof,lo,hi,ir)

    integer, intent(in   ) :: loc(:),lof(:)
    logical, intent(inout) ::    mask(loc(1):,loc(2):)
    integer, intent(in   ) :: mm_crse(loc(1):,loc(2):)
    integer, intent(in   ) :: mm_fine(lof(1):,lof(2):)
    integer, intent(in   ) :: lo(:),hi(:)
    integer, intent(in   ) :: ir(:)

    integer :: i,j,fi,fj

    do j = lo(2),hi(2)
       fj = j*ir(2)
       do i = lo(1),hi(1)
          fi = i*ir(1)
          if (.not.  bc_dirichlet(mm_fine(fi,fj),1,0) .or. bc_dirichlet(mm_crse(i,j),1,0)) &
               mask(i,j) = .false.
       end do
    end do

  end subroutine create_nodal_mask_2d

  subroutine create_nodal_mask_3d(mask,mm_crse,loc,mm_fine,lof,lo,hi,ir)

    integer, intent(in   ) :: loc(:),lof(:)
    logical, intent(inout) ::    mask(loc(1):,loc(2):,loc(3):)
    integer, intent(in   ) :: mm_crse(loc(1):,loc(2):,loc(3):)
    integer, intent(in   ) :: mm_fine(lof(1):,lof(2):,lof(3):)
    integer, intent(in   ) :: lo(:),hi(:)
    integer, intent(in   ) :: ir(:)

    integer :: i,j,k,fi,fj,fk

    !$OMP PARALLEL DO PRIVATE(i,j,k,fi,fj,fk)
    do k = lo(3),hi(3)
       fk = k*ir(3)
       do j = lo(2),hi(2)
          fj = j*ir(2)
          do i = lo(1),hi(1)
             fi = i*ir(1)
             if (.not. bc_dirichlet(mm_fine(fi,fj,fk),1,0) .or. bc_dirichlet(mm_crse(i,j,k),1,0) ) &
                  mask(i,j,k) = .false.
          end do
       end do
    end do
    !$OMP END PARALLEL DO

  end subroutine create_nodal_mask_3d

end module ml_solve_module
