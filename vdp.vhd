library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity vdp is
	generic (
		MAX_SPPL : integer := 7
	);
	port (
		clk_sys:			in  STD_LOGIC;
		ce_vdp:			in  STD_LOGIC;
		ce_pix:			in  STD_LOGIC;
		ce_sp:			in  STD_LOGIC;
		gg:				in  STD_LOGIC;
		sp64:				in  STD_LOGIC;
		TH_A:				in  STD_LOGIC;
		TH_B:				in  STD_LOGIC;
		RD_n:				in  STD_LOGIC;
		WR_n:				in  STD_LOGIC;
		IRQ_n:			out STD_LOGIC;
		A:					in  STD_LOGIC_VECTOR (7 downto 0);
		D_in:				in  STD_LOGIC_VECTOR (7 downto 0);
		D_out:			out STD_LOGIC_VECTOR (7 downto 0);
		x:					in  STD_LOGIC_VECTOR (8 downto 0);
		y:					in  STD_LOGIC_VECTOR (8 downto 0);
		color:			out STD_LOGIC_VECTOR (11 downto 0);
		reset_n:       in  STD_LOGIC);
end vdp;

architecture Behavioral of vdp is
	
	signal old_RD_n:			STD_LOGIC;
	signal old_WR_n:			STD_LOGIC;
	signal old_TH_A:			STD_LOGIC;
	signal old_TH_B:			STD_LOGIC;

	-- helper bits
	signal data_write:		std_logic;
	signal address_ff:		std_logic := '0';
	signal to_cram:			boolean := false;
	signal spr_collide:		std_logic;
	signal spr_overflow:		std_logic;
	
	-- vram and cram lines for the cpu interface
	signal xram_cpu_A:		std_logic_vector(13 downto 0);
	signal vram_cpu_WE:		std_logic;
	signal cram_cpu_WE:		std_logic;
	signal vram_cpu_D_out:	std_logic_vector(7 downto 0);	
	signal vram_cpu_D_outl:	std_logic_vector(7 downto 0);	
	signal xram_cpu_A_incr:	std_logic := '0';
	signal xram_cpu_read:	std_logic := '0';
	
	-- vram and cram lines for the video interface
	signal vram_vdp_A:		std_logic_vector(13 downto 0);
	signal vram_vdp_D:		std_logic_vector(7 downto 0);	
	signal cram_vdp_A:		std_logic_vector(4 downto 0);
	signal cram_vdp_D:		std_logic_vector(11 downto 0);
	signal cram_vdp_A_in:	std_logic_vector(4 downto 0);
	signal cram_vdp_D_in:	std_logic_vector(11 downto 0);
			
	-- control bits
	signal display_on:		std_logic := '1';
	signal disable_hscroll:	std_logic := '0';
	signal disable_vscroll: std_logic := '0';
	signal mask_column0:		std_logic := '0';
	signal overscan:			std_logic_vector (3 downto 0) := "0000";	
	signal irq_frame_en:		std_logic := '0';
	signal irq_line_en:		std_logic := '0';
	signal irq_line_count:	std_logic_vector(7 downto 0) := (others=>'1');	
	signal bg_address:		std_logic_vector (2 downto 0) := (others=>'0');
	signal bg_scroll_x:		std_logic_vector(7 downto 0) := (others=>'0');
	signal bg_scroll_y:		std_logic_vector(7 downto 0) := (others=>'0');
	signal spr_address:		std_logic_vector (5 downto 0) := (others=>'0');
	signal spr_shift:			std_logic := '0';
	signal spr_tall:			std_logic := '0';
	signal spr_high_bit:		std_logic := '0';

	-- various counters
	signal last_x0:			std_logic := '0';
	signal reset_flags:		boolean := false;
	signal irq_delay:       std_logic_vector(2 downto 0) := "111";
	signal collide_flag:		std_logic := '0';
	signal overflow_flag:	std_logic := '0';
	signal hbl_counter:		std_logic_vector(7 downto 0) := (others=>'0');
	signal vbl_irq:			std_logic;
	signal hbl_irq:			std_logic;
	signal latched_x:		std_logic_vector(7 downto 0);

	signal cram_latch:		std_logic_vector(7 downto 0);
	
begin
		
	vdp_main_inst: entity work.vdp_main
	generic map(
		MAX_SPPL => MAX_SPPL
	)
	port map(
		clk_sys			=> clk_sys,
		ce_vdp			=> ce_vdp,
		ce_pix			=> ce_pix,
		ce_sp				=> ce_sp,
		gg					=> gg,
		sp64				=> sp64,
		vram_A			=> vram_vdp_A,
		vram_D			=> vram_vdp_D,
		cram_A			=> cram_vdp_A,
		cram_D			=> cram_vdp_D,
				
		x					=> x,
		y					=> y,
		color				=> color,
						
		display_on		=> display_on,
		mask_column0	=> mask_column0,
		overscan			=> overscan,

		bg_address		=> bg_address,
		bg_scroll_x		=> bg_scroll_x,
		bg_scroll_y		=> bg_scroll_y,
		disable_hscroll=>disable_hscroll,
		disable_vscroll => disable_vscroll,

		spr_address		=> spr_address,
		spr_high_bit	=> spr_high_bit,
		spr_shift		=> spr_shift,
		spr_tall			=> spr_tall,
		spr_collide		=> spr_collide,
		spr_overflow	=> spr_overflow);

    
  vdp_vram_inst : entity work.dpram
    generic map
    (
      widthad_a		=> 14
    )
    port map
    (
      clock_a			=> clk_sys,
      address_a		=> xram_cpu_A(13 downto 0),
      wren_a			=> vram_cpu_WE,
      data_a			=> D_in,
      q_a				=> vram_cpu_D_out,

      clock_b			=> clk_sys,
      address_b		=> vram_vdp_A,
      wren_b			=> '0',
      data_b			=> (others => '0'),
      q_b				=> vram_vdp_D
    );

	vdp_cram_inst: entity work.vdp_cram
	port map (
		cpu_clk			=> clk_sys,
		cpu_WE			=> cram_cpu_WE,
		cpu_A 			=> cram_vdp_A_in,
		cpu_D				=> cram_vdp_D_in,
		vdp_clk			=> clk_sys,
		vdp_A				=> cram_vdp_A,
		vdp_D				=> cram_vdp_D
	);

	cram_vdp_A_in <= xram_cpu_A(4 downto 0) when gg='0' else xram_cpu_A(5 downto 1);
	cram_vdp_D_in <= (D_in(5 downto 4) & D_in(5 downto 4) & D_in(3 downto 2) & D_in(3 downto 2) & D_in(1 downto 0) & D_in(1 downto 0))
							when gg='0' else (D_in(3 downto 0) & cram_latch);
	cram_cpu_WE <= data_write when to_cram and ((gg='0') or (xram_cpu_A(0)='1')) else '0';
	vram_cpu_WE <= data_write when not to_cram else '0';

	process (clk_sys, reset_n)
	begin
		if reset_n='0' then
			disable_hscroll<= '0';--36
			disable_vscroll <= '0';
			mask_column0	<= '1';--
			irq_line_en		<= '1';--
			spr_shift		<= '0';--
			display_on		<= '0';--80
			irq_frame_en	<= '0';--
			spr_tall			<= '0';--
			bg_address		<= "111";--FF
			spr_address		<= "111111";--FF
			spr_high_bit	<= '0';--FB
			overscan			<= "0000";--00
			bg_scroll_x		<= (others => '0');--00
			bg_scroll_y		<= (others => '0');--00
			irq_line_count	<= (others=>'1');--FF
			reset_flags		<= true;
			address_ff		<= '0';
			xram_cpu_read	<= '0';
		elsif rising_edge(clk_sys) then
			data_write <= '0';

			if ce_vdp = '1' then
				old_WR_n <= WR_n;
				old_RD_n <= RD_n;

				old_TH_A <= TH_A;
				old_TH_B <= TH_B;
				if (old_TH_A = '0' and TH_A = '1') or (old_TH_B = '0' and TH_B = '1') then
					latched_x <= x(8 downto 1);
				end if;

				if old_WR_n = '1' and WR_n='0' then
					if A(0)='0' then
						data_write <= '1';
						xram_cpu_A_incr <= '1';
						address_ff		<= '0';
						vram_cpu_D_outl <= D_in;
						if (to_cram and xram_cpu_A(0)='0') then
							cram_latch <= D_in;
						end if;
					else
						if address_ff='0' then
							xram_cpu_A(7 downto 0) <= D_in;
						else
							xram_cpu_A(13 downto 8) <= D_in(5 downto 0);
							to_cram <= D_in(7 downto 6)="11";
							if D_in(7 downto 6)="00" then
								xram_cpu_read <= '1';
							end if;
							case D_in(7 downto 6)&D_in(3 downto 0) is
							when "100000" =>
								disable_vscroll <= xram_cpu_A(7);
								disable_hscroll<= xram_cpu_A(6);
								mask_column0	<= xram_cpu_A(5);
								irq_line_en		<= xram_cpu_A(4);
								spr_shift		<= xram_cpu_A(3);
							when "100001" =>
								display_on		<= xram_cpu_A(6);
								irq_frame_en	<= xram_cpu_A(5);
								spr_tall			<= xram_cpu_A(1);
							when "100010" =>
								bg_address		<= xram_cpu_A(3 downto 1);
							when "100101" =>
								spr_address		<= xram_cpu_A(6 downto 1);
							when "100110" =>
								spr_high_bit	<= xram_cpu_A(2);
							when "100111" =>
								overscan			<= xram_cpu_A(3 downto 0);
							when "101000" =>
								bg_scroll_x		<= xram_cpu_A(7 downto 0);
							when "101001" =>
								bg_scroll_y		<= xram_cpu_A(7 downto 0);
							when "101010" =>
								irq_line_count	<= xram_cpu_A(7 downto 0);
							when others =>
							end case;
						end if;
						address_ff <= not address_ff;
					end if;
					
				elsif old_RD_n = '1' and RD_n='0' then
					case A(7 downto 6)&A(0) is
					when "010" => -- VCounter
						D_out <= y(7 downto 0);
					when "011" => -- HCounter
						D_out <= latched_x;
					when "100" => -- Data port
						--D_out <= vram_cpu_D_out;
						address_ff <= '0';
						D_out <= vram_cpu_D_outl;
						xram_cpu_A_incr <= '1';
						xram_cpu_read <= '1';
					when "101" => --Ctrl port
						address_ff <= '0';
						D_out(7) <= vbl_irq;
						D_out(6) <= overflow_flag;
						D_out(5) <= collide_flag;
						D_out(4 downto 0) <= (others=>'0');
						reset_flags <= true;
					when others =>
					end case;
					
				elsif xram_cpu_A_incr='1' then
					xram_cpu_A <= xram_cpu_A + 1;
					xram_cpu_A_incr <= '0';
					if xram_cpu_read='1' then
						vram_cpu_D_outl <= vram_cpu_D_out;
					end if;
					xram_cpu_read <= '0';

				elsif xram_cpu_read='1' then
					xram_cpu_A_incr <= '1';

				else
					reset_flags <= false;
				end if;
			end if;
		end if;
	end process;

	process (clk_sys)
	begin
		if rising_edge(clk_sys) then
			if ce_vdp = '1' then
				if x=487 and y=192 and not (last_x0=std_logic(x(0))) then
					vbl_irq <= '1';
				elsif reset_flags then
					vbl_irq <= '0';
				end if;
			end if;
		end if;
	end process;
	
	process (clk_sys)
	begin
		if rising_edge(clk_sys) then
			if ce_vdp = '1' then
				last_x0 <= std_logic(x(0));
				if x=487 and not (last_x0=std_logic(x(0))) then
					if y<192 or y=511 then
						if hbl_counter=0 then
							hbl_irq <= irq_line_en;
							hbl_counter <= irq_line_count;
						else
							hbl_counter <= hbl_counter-1;
						end if;
					else
						hbl_counter <= irq_line_count;
					end if;
				elsif reset_flags then
					hbl_irq <= '0';
				end if;
			end if;
		end if;
	end process;

	process (clk_sys)
	begin
		if rising_edge(clk_sys) then
			if ce_vdp = '1' then
				if spr_collide='1' then
					collide_flag <= '1';
				end if;
				if reset_flags then
					collide_flag <= '0';
				end if;

				if spr_overflow='1' then
					overflow_flag <= '1';
				end if;
				if reset_flags then
					overflow_flag <= '0';
				end if;

				if (vbl_irq='1' and irq_frame_en='1') or (hbl_irq='1' and irq_line_en='1') then
					if irq_delay = "000" then
						IRQ_n <= '0';
					else
						irq_delay <= irq_delay - 1;
					end if;
				else
					IRQ_n <= '1';
					irq_delay <= "111";
				end if;
			end if;
		end if;
	end process;
	
end Behavioral;
